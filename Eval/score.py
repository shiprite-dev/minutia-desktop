"""Scores minutia-eval hypotheses against the fixture references and writes results.json and report.md.

Usage: python score.py <fixtures-dir> <results-dir> <normalizer-dir>
"""
import json
import pathlib
import re
import statistics
import sys
import unicodedata

import jiwer

FIX, RESULTS, NORMALIZER = (pathlib.Path(p) for p in sys.argv[1:4])
sys.path.insert(0, str(NORMALIZER))
from normalizer import BasicMultilingualTextNormalizer, EnglishTextNormalizer  # noqa: E402

ENGLISH = EnglishTextNormalizer()
MULTILINGUAL = BasicMultilingualTextNormalizer(remove_diacritics=False)
HESITATIONS = re.compile(r"\b(mm-hmm|uh-huh|um+|uh+|hmm+|mm+|mhm|er|erm|ah|huh)\b", re.IGNORECASE)
LOCAL = ["parakeet-v3", "parakeet-ultra", "parakeet-ja"]
ENGINES = LOCAL + ["groq-turbo"]
ENGLISH_CLASSES = ["read-clean", "read-other", "conversational", "conversational-echo", "meeting-full"]
RAM_BUDGET_MB, SPEED_FLOOR = 2048, 20.0


def normalize(text, lang):
    if lang == "en":
        return ENGLISH(HESITATIONS.sub(" ", text))
    return MULTILINGUAL(text)


def cer_chars(text):
    text = unicodedata.normalize("NFKC", text)
    return " ".join(c for c in text if unicodedata.category(c)[0] not in "PSZ")


def errors(ref, hyp, lang):
    if lang == "ja":
        out = jiwer.process_characters(cer_chars(ref).replace(" ", ""), cer_chars(hyp).replace(" ", "") or "")
    else:
        r, h = normalize(ref, lang), normalize(hyp, lang)
        if not r.strip():
            return None
        out = jiwer.process_words(r, h)
    return {"sub": out.substitutions, "del": out.deletions, "ins": out.insertions,
            "ref": out.substitutions + out.deletions + out.hits}


manifest = {i["id"]: i for i in json.loads((FIX / "manifest.json").read_text())["items"]}
runs = {e: json.loads(p.read_text()) for e in ENGINES if (p := RESULTS / f"transcribe-{e}.json").exists()}
prepared = {e: json.loads(p.read_text()) for e in LOCAL if (p := RESULTS / f"prepare-{e}.json").exists()}

rows = []
for engine, run in runs.items():
    for res in run["items"]:
        item = manifest[res["id"]]
        row = {"engine": engine, "id": res["id"], "class": item["class"], "channel": item["channel"],
               "lang": item["lang"], "durationSeconds": res["durationSeconds"], "wallSeconds": res["wallSeconds"],
               "xRealtime": res["xRealtime"], "noSpeech": res["noSpeech"], "segments": len(res["segments"]),
               "guardPasses": res["guardPasses"],
               "guardWindows": [dict(w, fails=w["start"] in res["guardFailingWindowStarts"]) for w in res["guardWindows"]], "error": res.get("error"),
               "hypothesis": res["text"], "errors": None,
               "hasTimings": all(s["end"] >= s["start"] >= 0 for s in res["segments"]) and bool(res["segments"])}
        if item["reference"] and not res.get("error"):
            row["errors"] = errors(item["reference"], res["text"], item["lang"])
        rows.append(row)


def aggregate(selected):
    scored = [r["errors"] for r in selected if r["errors"]]
    ref = sum(e["ref"] for e in scored)
    edits = sum(e["sub"] + e["del"] + e["ins"] for e in scored)
    audio = sum(r["durationSeconds"] for r in selected if not r["error"])
    wall = sum(r["wallSeconds"] for r in selected if not r["error"])
    return {"items": len(selected), "errors": sum(1 for r in selected if r["error"]),
            "errorRate": round(edits / ref * 100, 2) if ref else None, "refUnits": ref,
            "audioSeconds": round(audio, 1), "xRealtime": round(audio / wall, 1) if wall else None,
            "minItemXRealtime": round(min((r["xRealtime"] for r in selected if not r["error"]), default=0), 1)}


slices = {}
for engine in runs:
    mine = [r for r in rows if r["engine"] == engine]
    for klass in sorted({r["class"] for r in mine}):
        in_class = [r for r in mine if r["class"] == klass]
        slices[f"{engine}|{klass}|all"] = aggregate(in_class)
        for channel in sorted({r["channel"] for r in in_class} - {"mono"}):
            slices[f"{engine}|{klass}|{channel}"] = aggregate([r for r in in_class if r["channel"] == channel])
    slices[f"{engine}|read|all"] = aggregate([r for r in mine if r["class"].startswith("read-")])


def rate(engine, klass, channel="all"):
    return (slices.get(f"{engine}|{klass}|{channel}") or {}).get("errorRate")


def peak_extra(engine):
    run = runs.get(engine, {})
    return round(run.get("peakFootprintMB", 0) - run.get("baselineFootprintMB", 0), 0) if run else None


calibration = {}
for engine in ["parakeet-v3", "parakeet-ultra"]:
    english, japanese = [], []
    for r in rows:
        if r["engine"] != engine:
            continue
        for w in r["guardWindows"]:
            if w["speechSeconds"] < 3:
                continue
            if r["class"] in ENGLISH_CLASSES or (r["class"] == "spliced" and w["start"] < 30):
                english.append(w)
            elif r["class"] == "ja" or (r["class"] == "spliced" and w["start"] >= 30):
                japanese.append(w)

    def stats(ws, key):
        vals = sorted(w[key] for w in ws)
        if not vals:
            return None
        pick = lambda q: round(vals[min(len(vals) - 1, int(q * len(vals)))], 3)
        return {"n": len(vals), "min": pick(0), "p5": pick(0.05), "median": round(statistics.median(vals), 3),
                "p95": pick(0.95), "max": pick(0.9999)}

    calibration[engine] = {
        "english": {k: stats(english, k) for k in ("meanConfidence", "charsPerSpeechSecond")},
        "japanese": {k: stats(japanese, k) for k in ("meanConfidence", "charsPerSpeechSecond")},
        "englishWindowsFailing": sum(1 for w in english if w["fails"]),
        "japaneseWindowsPassing": sum(1 for w in japanese if not w["fails"]),
    }

gates = {}
for engine in ["parakeet-v3", "parakeet-ultra"]:
    if engine not in runs:
        continue
    by_id = {r["id"]: r for r in rows if r["engine"] == engine}
    full = [r for r in by_id.values() if r["class"] == "meeting-full"]
    groq_conv = rate("groq-turbo", "conversational")
    gates[engine] = {
        "readEnglishWerAtMost12": (rate(engine, "read") or 999) <= 12,
        "conversationalWerAtMost20": (rate(engine, "conversational") or 999) <= 20,
        "conversationalWithin3OfGroq": groq_conv is not None and (rate(engine, "conversational") or 999) - groq_conv <= 3,
        "atLeast20xRealtimePerChannel": bool(full) and all(r["xRealtime"] >= SPEED_FLOOR for r in full),
        "peakExtraRamUnder2GB": (peak_extra(engine) or 1e9) < RAM_BUDGET_MB,
        "silenceIsNoSpeech": by_id.get("silence-60s", {}).get("noSpeech") is True,
        "splicedTripsGuard": by_id.get("spliced-en-ja", {}).get("guardPasses") is False,
        "japaneseTripsGuard": all(not r["guardPasses"] for r in by_id.values() if r["class"] == "ja"),
        "segmentsHaveFiniteTimings": all(r["hasTimings"] for r in by_id.values() if r["segments"]),
    }

v3, ultra = rate("parakeet-v3", "conversational"), rate("parakeet-ultra", "conversational")
ultra_default = (v3 is not None and ultra is not None and v3 - ultra >= 1.0
                 and gates.get("parakeet-ultra", {}).get("atLeast20xRealtimePerChannel")
                 and gates.get("parakeet-ultra", {}).get("peakExtraRamUnder2GB"))

engines_info = {}
for engine, run in runs.items():
    info = {"modelId": run["modelId"], "loadSeconds": run.get("loadSeconds"), "peakExtraRamMB": peak_extra(engine) if engine in LOCAL else None}
    if engine in prepared:
        p = prepared[engine]
        info.update({"modelDir": p["modelDir"], "modelSizeMB": round(p["modelBytes"] / 1_048_576), "downloadAndCompileSeconds": round(p["downloadSeconds"], 1)})
    info["timestamps"] = "per-token (TokenTiming start/end/confidence), grouped into segments" if engine in LOCAL else "segment only requested (verbose_json); word granularity available"
    engines_info[engine] = info

results = {"engines": engines_info, "slices": slices, "gates": gates, "ultraBecomesDefault": bool(ultra_default),
           "guardCalibration": calibration, "rows": rows}
(RESULTS / "results.json").write_text(json.dumps(results, indent=1, ensure_ascii=False) + "\n")

fmt = lambda v, suffix="": "n/a" if v is None else f"{v}{suffix}"
lines = ["# Minutia on-device transcription eval", "",
         "WER: Open ASR Leaderboard normalizers (EnglishTextNormalizer for English, BasicMultilingualTextNormalizer for German), "
         "AMI hesitations stripped from reference and hypothesis alike, micro-averaged. Japanese: CER after NFKC with punctuation and spaces removed (informational).", "",
         "## Accuracy and speed", "",
         "| Engine | Class | Channel | Items | WER/CER % | x realtime | Min item x RT | Audio s |",
         "|---|---|---|---:|---:|---:|---:|---:|"]
for key, s in sorted(slices.items(), key=lambda kv: (ENGINES.index(kv[0].split("|")[0]), kv[0])):
    engine, klass, channel = key.split("|")
    lines.append(f"| {engine} | {klass} | {channel} | {s['items']}{' (' + str(s['errors']) + ' err)' if s['errors'] else ''} | "
                 f"{fmt(s['errorRate'])} | {fmt(s['xRealtime'])} | {fmt(s['minItemXRealtime'])} | {s['audioSeconds']} |")
lines += ["", "## Engines", "", "| Engine | Model | Size MB | Download + first compile s | Load s, new process | Peak extra RAM MB | Timestamps |", "|---|---|---:|---:|---:|---:|---|"]
for engine, i in engines_info.items():
    lines.append(f"| {engine} | {i['modelId']} | {fmt(i.get('modelSizeMB'))} | {fmt(i.get('downloadAndCompileSeconds'))} | "
                 f"{fmt(round(i['loadSeconds'], 2) if i['loadSeconds'] else None)} | {fmt(i['peakExtraRamMB'])} | {i['timestamps']} |")
lines += ["", "Load in a new process is a Core ML cache miss when this process last loaded a different model or the binary changed; "
          "a warm reload measures about 0.4 s. Peak extra RAM is the process phys_footprint peak minus the pre-load baseline; "
          "memory-mapped model weights and Neural Engine buffers are not in that ledger.",
          "", "conversational-echo is scored against the me reference only, so its WER is how much of the -20 dB echo each engine "
          "transcribes (the server echo filter's job), not a model quality number."]
lines += ["", "## Silence, noise and guard", "", "| Engine | Item | No speech | Segments | Guard passes | Hypothesis |", "|---|---|---|---:|---|---|"]
for r in rows:
    if r["class"] in ("silence", "noise", "spliced", "ja"):
        lines.append(f"| {r['engine']} | {r['id']} | {r['noSpeech']} | {r['segments']} | {r['guardPasses']} | {r['hypothesis'][:60].replace('|', ' ')} |")
lines += ["", "## Gates", "", "| Engine | " + " | ".join(next(iter(gates.values()), {}).keys()) + " |",
          "|---|" + "---|" * len(next(iter(gates.values()), {}))]
for engine, g in gates.items():
    lines.append(f"| {engine} | " + " | ".join("pass" if v else "FAIL" for v in g.values()) + " |")
lines += ["", f"Ultra becomes default: {'yes' if ultra_default else 'no'} (needs >= 1.0 absolute WER better than v3 on conversational, plus speed and RAM).",
          "", "## Quality guard calibration (30 s windows with at least 3 s of speech)", "", "```", json.dumps(calibration, indent=1), "```", ""]
(RESULTS / "report.md").write_text("\n".join(lines))
print("\n".join(lines))
