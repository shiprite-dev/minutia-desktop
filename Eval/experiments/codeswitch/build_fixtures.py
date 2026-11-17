"""Builds code-switched EN/JA fixtures from two captioned meetings. Usage: build_fixtures.py"""
import json, pathlib, random, re, subprocess
import numpy as np

SRC = pathlib.Path("/Volumes/Mango/tmp/minutia-eval-fixtures")
OUT = pathlib.Path("/Volumes/Mango/tmp/minutia-eval-codeswitch")
FIX = OUT / "fixtures"
SR, GAP = 16000, 0.3
LANGS = {"en": ("real/dmFENp1-lcM.flac", "raw/youtube/dmFENp1-lcM.en.vtt", 0.0, 1080.0),
         "ja": ("real/FrrrtE9HNOA.flac", "raw/youtube/FrrrtE9HNOA.ja.vtt", 1800.0, 3060.0)}


def ts(s):
    h, m, x = s.split(":")
    return int(h) * 3600 + int(m) * 60 + float(x)


def cues(vtt, offset, lo, hi):
    out, prev = [], 0.0
    for block in re.split(r"\n\n+", vtt.read_text()):
        lines = block.strip().split("\n")
        if not lines or "-->" not in lines[0]:
            continue
        a, b = (ts(x.strip().split()[0]) for x in lines[0].split("-->"))
        if a < lo or b > hi:
            continue
        text = " ".join(lines[1:])
        text = re.sub(r"<[^>]+>|\[[^\]]*\]", "", text)
        text = re.sub(r"^\s*[A-Z][\w .'-]{0,20}:\s+", "", text).strip()
        a = max(a - offset, prev)
        b = b - offset
        if b <= a or not text:
            continue
        out.append((a, b, text))
        prev = b
    return out


def pcm(path):
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", str(path), "-f", "s16le", "-ac", "1", "-ar", str(SR), "-"],
                         capture_output=True, check=True).stdout
    return np.frombuffer(raw, dtype=np.int16)


def build(name, seed, total_s, lo_turn, hi_turn, skip_s):
    rng = random.Random(seed)
    pool = {}
    for lang, (flac, vtt, offset, hi) in LANGS.items():
        pool[lang] = {"cues": cues(SRC / vtt_path(vtt), offset, offset, hi), "pcm": pcm(SRC / flac), "i": 0}
        while pool[lang]["cues"][pool[lang]["i"]][0] < skip_s:
            pool[lang]["i"] += 1
    audio, turns, t, lang = [], [], 0.0, "en"
    while t < total_s:
        p = pool[lang]
        target = rng.uniform(lo_turn, hi_turn)
        start_i = p["i"]
        while p["i"] < len(p["cues"]) and p["cues"][p["i"]][1] - p["cues"][start_i][0] < target:
            p["i"] += 1
        chunk = p["cues"][start_i:p["i"] + (1 if p["i"] < len(p["cues"]) and p["i"] == start_i else 0)] or p["cues"][start_i:start_i + 1]
        p["i"] = start_i + len(chunk)
        a, b = chunk[0][0], chunk[-1][1]
        seg = p["pcm"][int(a * SR):int(b * SR)]
        dur = len(seg) / SR
        audio += [seg, np.zeros(int(GAP * SR), dtype=np.int16)]
        turns.append({"start": round(t, 3), "end": round(t + dur, 3), "lang": lang,
                      "reference": (" " if lang == "en" else "").join(c[2] for c in chunk),
                      "source": {"start": round(a, 3), "end": round(b, 3)}})
        t += dur + GAP
        lang = "ja" if lang == "en" else "en"
    FIX.joinpath("codeswitch").mkdir(parents=True, exist_ok=True)
    raw = FIX / f"codeswitch/{name}.s16"
    raw.write_bytes(np.concatenate(audio).tobytes())
    flac = FIX / f"codeswitch/{name}.flac"
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "s16le", "-ar", str(SR), "-ac", "1", "-i", str(raw), str(flac)], check=True)
    raw.unlink()
    (OUT / f"{name}.reference.json").write_text(json.dumps({"id": name, "seed": seed, "durationSeconds": round(t, 3), "turns": turns},
                                                       ensure_ascii=False, indent=1))
    return {"id": name, "fixture": name, "channel": "mono", "class": name.replace("_", "-"), "lang": "en+ja",
            "path": f"codeswitch/{name}.flac", "durationSeconds": round(t, 3), "reference": "",
            "source": "EN/JA turns cut on caption boundaries from dmFENp1-lcM (CC BY 3.0) and FrrrtE9HNOA (CC BY 3.0)"}


def vtt_path(p):
    return p


items = [build("codeswitch", 29, 600, 15, 60, 0), build("codeswitch_fast", 31, 300, 4, 8, 400)]
(FIX / "manifest.json").write_text(json.dumps({"version": 1, "items": items}, ensure_ascii=False, indent=1))
for i in items:
    ref = json.loads((OUT / f"{i['id']}.reference.json").read_text())
    print(i["id"], i["durationSeconds"], len(ref["turns"]), "turns")
