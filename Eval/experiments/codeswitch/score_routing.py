"""Routing eval: per-segment z-pick, script heuristic, LID (whisper tiny/base, ecapa). Writes report-routing.md."""
import json, pathlib, statistics as st
src = open("/Volumes/Mango/tmp/minutia-eval-codeswitch/score_codeswitch.py").read().split("\ndef main():")[0]
exec(src)
OR2 = pathlib.Path("/Volumes/Mango/tmp/minutia-eval-results-or2")
lid = json.load(open(OUT / "lid_chunks.json"))
runs = {e: {i["id"]: i for i in json.loads((RES / f"transcribe-{e}.json").read_text())["items"]} for e in ["parakeet-ultra", "parakeet-ja"]}

def calib(engine, item):
    it = {i["id"]: i for i in json.loads((OR2 / f"transcribe-{engine}.json").read_text())["items"]}[item]
    c = [s["confidence"] for s in it["segments"] if s.get("confidence") is not None]
    qs = st.quantiles(c, n=4)
    return st.mean(c), st.pstdev(c), qs[0], len(c)
CAL = {"ultra": calib("parakeet-ultra", "real-en-dmFENp1-lcM"), "ja": calib("parakeet-ja", "real-ja-FrrrtE9HNOA")}
mid = lambda s: (s["start"] + s["end"]) / 2

def turn_lang_at(turns, t):
    return turns[turn_of(turns, t)]["lang"]

def score(turns, segs):
    texts = [[] for _ in turns]
    for s in sorted(segs, key=lambda s: s["start"]):
        texts[turn_of(turns, mid(s))].append(s["text"])
    acc = {"en": [0] * 5, "ja": [0] * 5}
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
    p = lambda x, n: round(100 * x / n, 1)
    return {"en_wer": p(sum(acc["en"][:3]), acc["en"][3]), "ja_cer": p(sum(acc["ja"][:3]), acc["ja"][3]),
            "m_en": p(acc["en"][4], acc["en"][3]), "m_ja": p(acc["ja"][4], acc["ja"][3])}

def by_chunks(chunks, choice, U, J):
    out = []
    for (a, b), c in zip(chunks, choice):
        src_ = U if c == "ultra" else J
        out += [s for s in src_ if a <= mid(s) < b or (b >= chunks[-1][1] and mid(s) >= b)]
    return out

def zscore(engine, s):
    mu, sd, _, _ = CAL[engine]
    return (s["confidence"] - mu) / sd

def zpick(U, J):
    items = sorted([("ultra", s) for s in U] + [("ja", s) for s in J], key=lambda x: x[1]["start"])
    clusters, cur, end = [], [], -1
    for e, s in items:
        if cur and s["start"] < end:
            cur.append((e, s)); end = max(end, s["end"])
        else:
            if cur: clusters.append(cur)
            cur, end = [(e, s)], s["end"]
    if cur: clusters.append(cur)
    out, picks = [], []
    for cl in clusters:
        sc = {}
        for e in ("ultra", "ja"):
            ss = [s for x, s in cl if x == e]
            d = sum(s["end"] - s["start"] for s in ss)
            if ss:
                sc[e] = sum(zscore(e, s) * (s["end"] - s["start"]) for s in ss) / max(d, 1e-6)
        pick = max(sc, key=sc.get)
        picks.append((pick, (cl[0][1]["start"] + max(s["end"] for _, s in cl)) / 2, len(sc)))
        out += [s for x, s in cl if x == pick]
    return out, picks

def heuristic(chunks, U, J, thr):
    ch = []
    for a, b in chunks:
        u = [s for s in U if a <= mid(s) < b]; j = [s for s in J if a <= mid(s) < b]
        jt = "".join(s["text"] for s in j)
        kana = sum(bool(JA_SCRIPT.match(c)) for c in jt)
        ulow = (not u) or st.mean(s["confidence"] for s in u) < thr
        ch.append("ja" if kana >= 3 and ulow else "ultra")
    return ch

def lid_choice(ps, name_ps):
    return ["ja" if p["ja"] > p["en"] else "ultra" for p in ps]

def chunk_truth(turns, chunks):
    return ["ja" if turn_lang_at(turns, (a + b) / 2) == "ja" else "ultra" for a, b in chunks]

def purity(turns, chunks):
    tot = pure = 0
    for (a, b), tr in zip(chunks, chunk_truth(turns, chunks)):
        n = 0
        t = a
        while t < b:
            n += (("ja" if turn_lang_at(turns, t) == "ja" else "ultra") == tr); t += 0.1
        tot += (b - a); pure += 0.1 * n
    return pure / tot

report = ["# Language-routed code-switch transcription (ultra vs ja)", "",
          "Same fixtures and Parakeet transcripts as report.md (no re-transcription). Scoring identical to report.md: segment midpoint decides the turn, EN WER with the Open ASR normalizer, JA CER after NFKC, missed = share of reference units in turns whose hypothesis is empty or in the wrong script. LID acc = share of decisions whose engine matches the true language of the unit's midpoint: per VAD chunk for the heuristic and LID rows, per overlap cluster for the z-pick, per 30 s window (majority turn language) for best-of-two.", ""]
summary = {}
tm = lid["timing_s_per_audio_min"]
for fid in ["codeswitch", "codeswitch_fast"]:
    turns = json.loads((OUT / f"{fid}.reference.json").read_text())["turns"]
    ru, rj = runs["parakeet-ultra"][fid], runs["parakeet-ja"][fid]
    U, J = ru["segments"], rj["segments"]
    chunks = lid["fixtures"][fid]["chunks"]
    truth = chunk_truth(turns, chunks)
    rows = []
    orc = [s for s in U if turn_lang_at(turns, mid(s)) == "en"] + [s for s in J if turn_lang_at(turns, mid(s)) == "ja"]
    rows.append(("oracle", score(turns, orc), "100.0", "none (runs both engines)"))
    b2, choices = pick_best(ru, rj, confidence_pick)
    ok = 0
    for s0, c in choices.items():
        mix = {"en": 0, "ja": 0}
        t = s0
        while t < s0 + W:
            mix[turn_lang_at(turns, t)] += 1; t += 0.5
        ok += (("ultra" if mix["en"] >= mix["ja"] else "ja") == c)
    rows.append(("best-of-two (30 s)", score(turns, b2), f"{100 * ok / len(choices):.1f}", "none (runs both engines)"))
    zs, picks = zpick(U, J)
    two = [p for p in picks if p[2] == 2]
    zacc = sum((("ultra" if turn_lang_at(turns, p[1]) == "en" else "ja") == p[0]) for p in two) / max(len(two), 1)
    rows.append(("per-segment z-pick", score(turns, zs), f"{100 * zacc:.1f} ({len(two)} contested of {len(picks)} clusters)", "none (runs both engines)"))
    thr = CAL["ultra"][2]
    hc = heuristic(chunks, U, J, thr)
    hacc = sum(a == b for a, b in zip(hc, truth)) / len(truth)
    rows.append(("script heuristic", score(turns, by_chunks(chunks, hc, U, J)), f"{100 * hacc:.1f}", "none (runs both engines); ultra conf < p25 of EN calibration"))
    lid_acc = {}
    for name, label, cost in [("whisper-tiny", "LID whisper-tiny", f"{tm['whisper-tiny']:.2f} s CPU per audio min"),
                              ("whisper-base", "LID whisper-base", f"{tm['whisper-base']:.2f} s CPU per audio min"),
                              ("ecapa", "LID ecapa", f"{tm['ecapa']:.2f} s CPU per audio min")]:
        ch = lid_choice(lid["fixtures"][fid]["lid"][name], name)
        acc = sum(a == b for a, b in zip(ch, truth)) / len(truth)
        sec = sum((b - a) for (a, b), x, y in zip(chunks, ch, truth) if x == y) / sum(b - a for a, b in chunks)
        lid_acc[name] = acc
        rows.append((label, score(turns, by_chunks(chunks, ch, U, J)), f"{100 * acc:.1f} ({100 * sec:.1f} by seconds)", cost + " plus both engines" ))
    summary[fid] = {r[0]: r[1] for r in rows}
    report += [f"## {fid}", "", f"{len(chunks)} VAD chunks (2 to 6 s), true-language purity {100 * purity(turns, chunks):.1f}% of audio seconds.", "",
               "| Option | EN WER % | JA CER % | Missed EN % | Missed JA % | LID acc % | Extra cost |", "|---|---:|---:|---:|---:|---:|---|"]
    for n, r, a, c in rows:
        report.append(f"| {n} | {r['en_wer']} | {r['ja_cer']} | {r['m_en']} | {r['m_ja']} | {a} | {c} |")
    report.append("")
report += ["## Calibration (z-pick)", "",
           "Per-model segment confidence on its matching-language single-language item from results-or2: " +
           "; ".join(f"{k}: n={v[3]}, mean {v[0]:.3f}, sd {v[1]:.3f}, p25 {v[2]:.3f}" for k, v in CAL.items()) +
           ". z = (segment confidence - mean) / sd; an overlap cluster (transitively time-overlapping ultra and ja segments) takes the engine with the higher duration-weighted mean z. Clusters with segments from one engine only keep them. Calibration audio is the same source video as the fixture turns (real-en-dmFENp1-lcM, real-ja-FrrrtE9HNOA), so z-pick sees in-distribution calibration.", ""]
(RES / "report-routing.md").write_text("\n".join(report) + "\n")
print("\n".join(report))
