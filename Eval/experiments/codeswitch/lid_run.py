"""Energy-VAD chunking (2-6 s) + LID probabilities for en/ja. Writes lid_chunks.json."""
import json, time, sys, pathlib
import numpy as np, soundfile as sf, torch
OUT = pathlib.Path("/Volumes/Mango/tmp/minutia-eval-codeswitch")
SR = 16000

def chunks(x):
    fr = 320
    n = len(x) // fr
    e = np.sqrt((x[: n * fr].reshape(n, fr) ** 2).mean(1)) + 1e-9
    thr = max(np.percentile(e, 10) * 2.0, 0.003)
    quiet = e < thr
    out, start, i = [], 0, 0
    while start < n:
        end = None
        j = start + 100  # min 2 s
        while j < min(n, start + 300):
            if quiet[j] and quiet[j - 1] and (j + 1 >= n or quiet[j + 1]):
                end = j; break
            j += 1
        if end is None:
            end = min(n, start + 300)
            if end - start > 200 and end < n:
                seg = e[start + 200:end]; end = start + 200 + int(seg.argmin())
        if n - end < 100:
            end = n
        out.append((start * 0.02, end * 0.02)); start = end
    return out

def load_all():
    data = {}
    for fid in ["codeswitch", "codeswitch_fast"]:
        x, sr = sf.read(OUT / f"fixtures/codeswitch/{fid}.flac", dtype="float32")
        assert sr == SR
        data[fid] = x if x.ndim == 1 else x.mean(1)
    return data

def main():
    data = load_all()
    res = {fid: {"chunks": chunks(x), "lid": {}} for fid, x in data.items()}
    total_min = sum(len(x) for x in data.values()) / SR / 60
    timing = {}
    import whisper
    for name in ["tiny", "base"]:
        m = whisper.load_model(name, device="cpu", download_root=str(OUT / "cache/whisper"))
        t0 = time.time()
        for fid, x in data.items():
            ps = []
            for a, b in res[fid]["chunks"]:
                a_, b_ = int(a * SR), int(b * SR)
                seg = whisper.pad_or_trim(torch.from_numpy(x[a_:b_]))
                mel = whisper.log_mel_spectrogram(seg, n_mels=m.dims.n_mels).to("cpu")
                _, p = m.detect_language(mel)
                ps.append({"en": p["en"], "ja": p["ja"]})
            res[fid]["lid"][f"whisper-{name}"] = ps
        timing[f"whisper-{name}"] = (time.time() - t0) / total_min
        print(name, timing[f"whisper-{name}"], flush=True)
    from speechbrain.inference.classifiers import EncoderClassifier
    c = EncoderClassifier.from_hparams(source="speechbrain/lang-id-voxlingua107-ecapa", savedir=str(OUT / "cache/ecapa"), run_opts={"device": "cpu"})
    labs = c.hparams.label_encoder.ind2lab
    ien = [k for k, v in labs.items() if v.startswith("en")][0]; ija = [k for k, v in labs.items() if v.startswith("ja")][0]
    print(labs[ien], labs[ija])
    t0 = time.time()
    for fid, x in data.items():
        ps = []
        for a, b in res[fid]["chunks"]:
            seg = torch.from_numpy(x[int(a * SR):int(b * SR)])[None]
            lp = c.classify_batch(seg)[0][0]
            ps.append({"en": float(lp[ien].exp()), "ja": float(lp[ija].exp())})
        res[fid]["lid"]["ecapa"] = ps
    timing["ecapa"] = (time.time() - t0) / total_min
    print("ecapa", timing["ecapa"])
    json.dump({"timing_s_per_audio_min": timing, "fixtures": res}, open(OUT / "lid_chunks.json", "w"))

main()
