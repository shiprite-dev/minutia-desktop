"""Scores code-switch runs per turn language, simulates best-of-two and oracle, writes report.md and codeswitch-results.json."""
import json, pathlib, re, sys, unicodedata
import jiwer

TOOLS = pathlib.Path("/Volumes/Mango/tmp/minutia-eval-tools")
sys.path.insert(0, str(TOOLS))
from normalizer import EnglishTextNormalizer  # noqa: E402

OUT = pathlib.Path("/Volumes/Mango/tmp/minutia-eval-codeswitch")
RES = pathlib.Path("/Volumes/Mango/tmp/minutia-eval-results-codeswitch")
EN = EnglishTextNormalizer()
HES = re.compile(r"\b(mm-hmm|uh-huh|um+|uh+|hmm+|mm+|mhm|er|erm|ah|huh)\b", re.IGNORECASE)
JA_SCRIPT = re.compile(r"[぀-ヿ㐀-䶿一-鿿ｦ-ﾟ]")
LATIN = re.compile(r"[A-Za-z]")
W = 30.0


def cer_text(t):
    return "".join(c for c in unicodedata.normalize("NFKC", t) if unicodedata.category(c)[0] not in "PSZ")


def en_norm(t):
    return EN(HES.sub(" ", t))


def edits(ref, hyp, lang):
    if lang == "ja":
        r, h = cer_text(ref), cer_text(hyp)
        if not r:
            return None
        o = jiwer.process_characters(r, h) if h else None
        n = len(r)
        return (o.substitutions, o.deletions, o.insertions, n) if o else (0, n, 0, n)
    r, h = en_norm(ref), en_norm(hyp)
    if not r.strip():
        return None
    n = len(r.split())
    if not h.strip():
        return (0, n, 0, n)
    o = jiwer.process_words(r, h)
    return (o.substitutions, o.deletions, o.insertions, n)


def wrong_script(hyp, lang):
    if lang == "ja":
        chars = cer_text(hyp)
        return len(chars) == 0 or sum(bool(JA_SCRIPT.match(c)) for c in chars) / len(chars) < 0.5
    letters = [c for c in hyp if c.isalpha()]
    return len(letters) == 0 or sum(bool(LATIN.match(c)) for c in letters) / len(letters) < 0.5


def turn_of(turns, mid):
    for i, t in enumerate(turns):
        if mid <= t["end"] + 0.15:
            return i
    return len(turns) - 1


def pick_best(ultra, ja, key):
    """Per 30 s guard window, keep the engine's segments whose reported meanConfidence is higher."""
    uw = {w["start"]: w["meanConfidence"] for w in ultra["guardWindows"]}
    jw = {w["start"]: w["meanConfidence"] for w in ja["guardWindows"]}
    segs, choices = [], {}
    for start in sorted(set(uw) | set(jw)):
        choice = key(start, uw, jw)
        choices[start] = choice
        src = ultra if choice == "ultra" else ja
        segs += [s for s in src["segments"] if int(s["start"] // W) * W == start]
    return segs, choices


def confidence_pick(start, uw, jw):
    return "ultra" if uw.get(start, -1) >= jw.get(start, -1) else "ja"


def main():
    runs = {e: {i["id"]: i for i in json.loads(p.read_text())["items"]}
            for e in ["parakeet-ultra", "parakeet-ja", "groq-turbo"] if (p := RES / f"transcribe-{e}.json").exists()}
    report = ["# Code-switch transcription eval (English and Japanese in one meeting)", "",
              "Turn language comes from construction. Each hypothesis segment is assigned to the turn containing its timestamp midpoint "
              "(a 0.15 s grace into the following gap). EN turns: WER with the Open ASR English normalizer (hesitations stripped). "
              "JA turns: CER after NFKC with punctuation, symbols and spaces removed. Missed % = share of reference words (EN) or characters (JA) "
              "in turns whose hypothesis is empty or in the wrong script (under 50% Japanese-script characters for JA turns, under 50% Latin letters for EN turns). "
              "x realtime = fixture audio seconds over wall seconds, including decode; best-of-two and oracle run both local engines, so their speed is audio over the sum of both wall times. "
              "Groq ran with `language` unset (Whisper auto-detect), as the harness sends no language field.", ""]
    summary = {}
    for fid in ["codeswitch", "codeswitch_fast"]:
        ref = json.loads((OUT / f"{fid}.reference.json").read_text())
        turns = ref["turns"]
        cid = fid
        hyps = {}
        wall = {}
        for e, items in runs.items():
            r = items.get(cid)
            if r and not r.get("error"):
                hyps[e] = r["segments"]
                wall[e] = r["wallSeconds"]
        ultra, ja = runs["parakeet-ultra"][cid], runs["parakeet-ja"][cid]
        hyps["best-of-two"], choices = pick_best(ultra, ja, confidence_pick)
        wall["best-of-two"] = ultra["wallSeconds"] + ja["wallSeconds"]
        oracle_segs, oracle_choices = [], {}
        by_turn_lang = {}
        for k, t in enumerate(turns):
            by_turn_lang[k] = "ultra" if t["lang"] == "en" else "ja"
        for e_name, src in (("ultra", ultra), ("ja", ja)):
            for s in src["segments"]:
                mid = (s["start"] + s["end"]) / 2
                if by_turn_lang[turn_of(turns, mid)] == e_name:
                    oracle_segs.append(s)
        hyps["oracle"] = sorted(oracle_segs, key=lambda s: s["start"])
        wall["oracle"] = wall["best-of-two"]
        names = {"parakeet-ultra": "ultra", "parakeet-ja": "ja", "best-of-two": "best-of-two", "oracle": "oracle", "groq-turbo": "groq"}
        order = ["parakeet-ultra", "parakeet-ja", "best-of-two", "oracle", "groq-turbo"]
        rows, detail = [], {}
        for e in order:
            if e not in hyps:
                continue
            texts = [[] for _ in turns]
            for s in hyps[e]:
                texts[turn_of(turns, (s["start"] + s["end"]) / 2)].append(s["text"])
            acc = {"en": [0, 0, 0, 0, 0, 0], "ja": [0, 0, 0, 0, 0, 0]}
            for t, parts in zip(turns, texts):
                hyp = (" " if t["lang"] == "en" else "").join(parts)
                m = edits(t["reference"], hyp, t["lang"])
                if m is None:
                    continue
                a = acc[t["lang"]]
                for j in range(4):
                    a[j] += m[j]
                if wrong_script(hyp, t["lang"]):
                    a[4] += m[3]
                a[5] += 1
            pct = lambda x, n: round(100 * x / n, 1) if n else None
            en, jp = acc["en"], acc["ja"]
            rec = {"en_wer": pct(sum(en[:3]), en[3]), "ja_cer": pct(sum(jp[:3]), jp[3]),
                   "en_del": pct(en[1], en[3]), "ja_del": pct(jp[1], jp[3]),
                   "missed_en": pct(en[4], en[3]), "missed_ja": pct(jp[4], jp[3]),
                   "xrt": round(ref["durationSeconds"] / wall[e], 1) if e in wall else None}
            detail[names[e]] = rec
            rows.append((names[e], rec))
        summary[fid] = {"detail": detail, "windowChoices": choices,
                        "turns": len(turns), "enTurns": sum(t["lang"] == "en" for t in turns), "jaTurns": sum(t["lang"] == "ja" for t in turns),
                        "refEnWords": en[3], "refJaChars": jp[3], "duration": ref["durationSeconds"]}
        f = lambda v: "n/a" if v is None else f"{v}"
        report += [f"## {fid} ({ref['durationSeconds']:.0f} s, {len(turns)} turns: {summary[fid]['enTurns']} EN, {summary[fid]['jaTurns']} JA; "
                   f"{en[3]} reference EN words, {jp[3]} reference JA characters)", "",
                   "| Option | EN WER % | JA CER % | Missed EN % | Missed JA % | x realtime |", "|---|---:|---:|---:|---:|---:|"]
        for n, r in rows:
            report.append(f"| {n} | {f(r['en_wer'])} | {f(r['ja_cer'])} | {f(r['missed_en'])} | {f(r['missed_ja'])} | {f(r['xrt'])} |")
        report += ["", "Deleted share of reference units (speech dropped inside turns, not only wrong-script turns):", "",
                   "| Option | EN deleted % | JA deleted % |", "|---|---:|---:|"]
        for n, r in rows:
            report.append(f"| {n} | {f(r['en_del'])} | {f(r['ja_del'])} |")
        picks = list(choices.values())
        right = 0
        total = 0
        for start, c in choices.items():
            idx = turn_of(turns, start + W / 2)
            total += 1
        chosen = {"ultra": picks.count("ultra"), "ja": picks.count("ja")}
        report += ["", f"Best-of-two window choices ({int(W)} s guard windows, higher meanConfidence wins): {chosen['ultra']} ultra, {chosen['ja']} ja of {len(picks)}.", ""]
    report += ["## Method notes and caveats", "",
               "- Best-of-two uses the harness guard windows, which are 30 s (QualityGuard.windowSeconds), not 15 s. A window takes all segments of the engine with the higher duration-weighted mean token confidence, so in the fast variant (4 to 8 s turns) most windows hold both languages and one engine must lose the other language's speech.",
               "- Oracle takes each segment from the engine matching the language of the turn its midpoint falls in (ultra for EN turns, ja for JA turns). It is the ceiling for any per-segment router, not for a per-window one.",
               "- Segment-midpoint assignment is coarse: a hypothesis segment spanning a turn boundary is credited wholly to one turn, which moves errors between turns. This matters most in the fast variant and for Groq, whose segments can cover up to 30 s.",
               "- References are the uploaders' manual captions, cut at caption boundaries. Caption timing drifts by a fraction of a second, captions clean up fillers and false starts and the English captions have speaker labels (stripped here); the Japanese captions are loose paraphrases in places. Absolute error rates therefore carry a floor, so compare options, not absolute values.",
               "- Segments are turn-ordered text per turn, so a hypothesis that reorders text across turns cannot be repaired. Parakeet ja was run on both fixtures because their manifest language is en+ja."]
    (RES / "report.md").write_text("\n".join(report) + "\n")
    (RES / "codeswitch-results.json").write_text(json.dumps(summary, indent=1, ensure_ascii=False))
    print("\n".join(report))


main()
