"""Runs one OpenVoiceOS ja variant (TDT path of the shipped infer.py) over fixtures in 15 s windows.
Usage: ja_run.py <variant-dir> <infer.py> <manifest.json> <fixtures-dir> <out.json> [CPU_AND_NE|ALL]"""
import importlib.util, json, resource, sys, time
from pathlib import Path
import coremltools as ct, numpy as np, soundfile as sf

repo, infer_py, manifest, fixdir, out = (Path(a) for a in sys.argv[1:6])
cu = {"ALL": ct.ComputeUnit.ALL, "CPU_AND_NE": ct.ComputeUnit.CPU_AND_NE}[sys.argv[6] if len(sys.argv) > 6 else "ALL"]
spec = importlib.util.spec_from_file_location("infer", infer_py); infer = importlib.util.module_from_spec(spec); spec.loader.exec_module(infer)
meta = json.loads((repo / "metadata.json").read_text()); vocab = json.loads((repo / "vocab.json").read_text())
N = meta["max_audio_samples"]; blank = meta["blank_id"]

def rss_mb(): return resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1e6
base = rss_mb(); t0 = time.time()
import subprocess
def comp(n):
    d = Path("/Volumes/Mango/tmp/minutia-eval-q4/compiled") / repo.name; d.mkdir(parents=True, exist_ok=True)
    if not (d / (n + ".mlmodelc")).exists():
        subprocess.run(["xcrun", "coremlcompiler", "compile", str(repo / (n + ".mlpackage")), str(d)], check=True)
    return str(d / (n + ".mlmodelc"))
mel_enc = ct.models.CompiledMLModel(comp("parakeet_mel_encoder"), compute_units=cu)
dec = ct.models.CompiledMLModel(comp("parakeet_decoder"), compute_units=ct.ComputeUnit.CPU_ONLY)
jd = ct.models.CompiledMLModel(comp("parakeet_joint_decision_single_step"), compute_units=cu)
load_s = time.time() - t0
bins = meta.get("duration_bins", []); ins = meta["components"]["decoder"]["inputs"]["h_in"]

def chunk(x):
    audio = np.pad(x, (0, N - len(x))).reshape(1, -1).astype(np.float32)
    o = mel_enc.predict({"audio_signal": audio, "audio_length": np.array([len(x)], dtype=np.int32)})
    return infer.decode_tdt(o["encoder"], int(o["encoder_length"][0]), dec, jd, vocab, blank, bins, ins[0], ins[2])

items = [i for i in json.loads(manifest.read_text())["items"] if i["id"] == "real-ja-FrrrtE9HNOA" or i["id"].startswith("fleurs-ja")]
res = []
peak_after_load = rss_mb()
for it in items:
    data, sr = sf.read(fixdir / it["path"], dtype="float32"); assert sr == 16000
    t = time.time(); text = " ".join(chunk(data[s:s + N]) for s in range(0, len(data), N)); wall = time.time() - t
    res.append({"id": it["id"], "durationSeconds": len(data) / sr, "wallSeconds": wall, "text": text})
    print(it["id"], round(len(data) / sr / wall, 1), "xRT", flush=True)
out.write_text(json.dumps({"variant": repo.name, "computeUnits": str(cu), "loadSeconds": load_s, "baselineRssMB": base,
    "afterLoadRssMB": peak_after_load, "peakRssMB": rss_mb(), "items": res}))
