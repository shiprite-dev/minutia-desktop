"""Builds the eval fixtures from the raw downloads into 16 kHz mono FLAC plus manifest.json.

Usage: python3 -I build_fixtures.py <fixtures-dir> <repo-manifest-path>
Selection is deterministic so every run yields the same audio and references.
"""
import csv
import json
import pathlib
import subprocess
import sys
import tarfile
import xml.etree.ElementTree as ET

import numpy as np

FIX = pathlib.Path(sys.argv[1])
RAW = FIX / "raw"
REPO_MANIFEST = pathlib.Path(sys.argv[2])
AMI_EXCERPTS = {"ES2004a": (300.0, 600.0), "IS1009a": (300.0, 600.0)}
AMI_FULL = "ES2004a"
NITE = "{http://nite.sourceforge.net/}"
items = []


def ffmpeg(*args):
    subprocess.run(["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-y", *args], check=True)


def duration(path):
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(path)],
                         check=True, capture_output=True, text=True).stdout
    return round(float(out), 3)


def add(item_id, fixture, channel, klass, lang, path, reference, source):
    items.append({"id": item_id, "fixture": fixture, "channel": channel, "class": klass, "lang": lang,
                  "path": str(path.relative_to(FIX)), "durationSeconds": duration(path),
                  "reference": reference, "source": source})


def flac(src, dst, *filters):
    dst.parent.mkdir(parents=True, exist_ok=True)
    ffmpeg("-i", str(src), *(["-af", ",".join(filters)] if filters else []), "-ac", "1", "-ar", "16000", "-sample_fmt", "s16", str(dst))


def librispeech(subset, klass):
    import pyarrow.parquet as pq
    table = pq.read_table(RAW / f"ls-{subset}.parquet", columns=["id", "text", "audio"]).to_pylist()
    rows = {r["id"]: r for r in table}
    ids = sorted(rows)
    chosen = [ids[i * len(ids) // 10] for i in range(10)]
    paths = []
    for uid in chosen:
        dst = FIX / "librispeech" / subset / f"{uid}.flac"
        dst.parent.mkdir(parents=True, exist_ok=True)
        dst.write_bytes(rows[uid]["audio"]["bytes"])
        paths.append(dst)
        add(f"ls-{subset}-{uid}", f"librispeech-{subset}", "mono", klass, "en", dst, rows[uid]["text"],
            f"LibriSpeech {subset} {uid} (openslr.org/12 via openslr/librispeech_asr, CC BY 4.0)")
    return paths


def ami_words(meeting):
    channels = {}
    meetings = ET.parse(FIX / "ami-ann" / "corpusResources" / "meetings.xml").getroot()
    for meet in meetings.iter("meeting"):
        if meet.get("observation") == meeting:
            for spk in meet.iter("speaker"):
                channels[spk.get("nxt_agent")] = int(spk.get("channel"))
    words = {}
    for agent in channels:
        tree = ET.parse(FIX / "ami-ann" / "words" / f"{meeting}.{agent}.words.xml").getroot()
        words[agent] = [(float(w.get("starttime")), float(w.get("endtime")), w.text.strip())
                        for w in tree.iter("w") if w.get("punc") != "true" and w.text and w.get("starttime")]
    return channels, words


def pcm(path, start, end):
    raw = subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-ss", str(start), "-to", str(end), "-i", str(path),
                          "-ac", "1", "-ar", "16000", "-f", "f32le", "-"], check=True, capture_output=True).stdout
    return np.frombuffer(raw, dtype=np.float32).copy()


def write_flac(samples, dst):
    subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-f", "f32le", "-ar", "16000", "-ac", "1", "-i", "-",
                    "-sample_fmt", "s16", str(dst)], input=samples.astype(np.float32).tobytes(), check=True)


def gate(samples, words, start, pad=0.2, merge=0.5):
    """Keeps only the speaker's own talk spurts, so headset bleed from the other talkers does not leak in."""
    keep = np.zeros(len(samples), dtype=bool)
    spans = []
    for w_start, w_end, _ in words:
        if spans and w_start - spans[-1][1] < merge:
            spans[-1][1] = max(spans[-1][1], w_end)
        else:
            spans.append([w_start, w_end])
    for a, b in spans:
        keep[max(0, int((a - pad - start) * 16000)):int((b + pad - start) * 16000)] = True
    return np.where(keep, samples, 0)


def ami(meeting, start, end, klass, tag):
    channels, words = ami_words(meeting)
    inside = {a: [w for w in ws if w[0] >= start and w[1] <= end] for a, ws in words.items()}
    me = max(inside, key=lambda a: len(inside[a]))
    others = sorted(a for a in channels if a != me)
    out = FIX / "ami" / f"{meeting}-{tag}"
    out.mkdir(parents=True, exist_ok=True)
    tracks = {a: gate(pcm(RAW / f"{meeting}.Headset-{channels[a]}.wav", start, end), inside[a], start) for a in channels}
    length = min(len(t) for t in tracks.values())
    me_audio = tracks[me][:length]
    them_audio = sum(tracks[a][:length] for a in others)
    them_audio = them_audio / max(np.abs(them_audio).max(), 1e-9) * 0.99

    me_path, them_path = out / "me.flac", out / "them.flac"
    write_flac(me_audio, me_path)
    write_flac(them_audio, them_path)

    me_ref = " ".join(w[2] for w in inside[me])
    them_ref = " ".join(w[2] for w in sorted((w for a in others for w in inside[a]), key=lambda w: w[0]))
    source = (f"AMI Meeting Corpus {meeting} individual headsets {start:.0f}-{end:.0f}s, me=agent {me}, "
              "each headset gated to its own talk spurts (CC BY 4.0)")
    fixture = f"ami-{meeting.lower()}-{tag}"
    add(f"{fixture}-me", fixture, "me", klass, "en", me_path, me_ref, source)
    add(f"{fixture}-them", fixture, "them", klass, "en", them_path, them_ref, source)

    if klass == "conversational":
        delay = int(0.080 * 16000)
        echo = me_audio + np.concatenate([np.zeros(delay, dtype=np.float32), them_audio[:-delay]]) * 10 ** (-20 / 20)
        echo_path = out / "me-echo.flac"
        write_flac(np.clip(echo, -1, 1), echo_path)
        add(f"{fixture}-me-echo", fixture, "me-echo", "conversational-echo", "en", echo_path, me_ref,
            source + "; them mixed into me at -20 dB, 80 ms delay")


def fleurs(lang, count, klass, skip=0):
    rows, seen = [], set()
    with open(RAW / f"fleurs-{lang}-dev.tsv", newline="") as f:
        for row in csv.reader(f, delimiter="\t", quoting=csv.QUOTE_NONE):
            if row[0] not in seen:
                seen.add(row[0])
                rows.append(row)
    rows = rows[skip:skip + count]
    tmp = FIX / "raw" / f"fleurs-{lang}"
    wanted = {f"dev/{r[1]}" for r in rows}
    if not all((tmp / w).exists() for w in wanted):
        with tarfile.open(RAW / f"fleurs-{lang}-dev.tar.gz") as tar:
            tar.extractall(tmp, members=[m for m in tar if m.name in wanted], filter="data")
    paths = []
    for row in rows:
        dst = FIX / "fleurs" / lang / f"{row[0]}.flac"
        flac(tmp / "dev" / row[1], dst)
        paths.append(dst)
        if klass:
            add(f"fleurs-{lang}-{row[0]}", f"fleurs-{lang}", "mono", klass, lang.split("_")[0], dst, row[2],
                f"FLEURS {lang} dev id {row[0]} (google/fleurs, CC BY 4.0)")
    return paths


def concat_trim(paths, seconds, dst):
    listing = dst.with_suffix(".txt")
    listing.write_text("".join(f"file '{p}'\n" for p in paths))
    ffmpeg("-f", "concat", "-safe", "0", "-i", str(listing), "-t", str(seconds), "-ac", "1", "-ar", "16000",
           "-sample_fmt", "s16", str(dst))
    listing.unlink()


clean = librispeech("test-clean", "read-clean")
librispeech("test-other", "read-other")
for meeting, (start, end) in AMI_EXCERPTS.items():
    ami(meeting, start, end, "conversational", "5m")
ami(AMI_FULL, 0.0, duration(RAW / f"{AMI_FULL}.Headset-0.wav"), "meeting-full", "full")
fleurs("de_de", 10, "de")
fleurs("ja_jp", 5, "ja")

synth = FIX / "synthetic"
synth.mkdir(parents=True, exist_ok=True)
english, japanese = synth / "en30.flac", synth / "ja30.flac"
concat_trim(clean, 30, english)
concat_trim(fleurs("ja_jp", 8, None, skip=5), 30, japanese)
spliced = synth / "spliced-en-ja.flac"
concat_trim([english, japanese], 60, spliced)
english.unlink()
japanese.unlink()
add("spliced-en-ja", "spliced-en-ja", "mono", "spliced", "en+ja", spliced, None,
    "30 s LibriSpeech test-clean then 30 s FLEURS ja_jp dev (CC BY 4.0)")
ffmpeg("-f", "lavfi", "-i", "anullsrc=r=16000:cl=mono", "-t", "60", "-sample_fmt", "s16", str(synth / "silence.flac"))
add("silence-60s", "silence", "mono", "silence", "none", synth / "silence.flac", None, "generated digital silence")
ffmpeg("-f", "lavfi", "-i", "anoisesrc=r=16000:color=pink:amplitude=0.003:seed=7", "-t", "60", "-ac", "1",
       "-sample_fmt", "s16", str(synth / "pink-noise.flac"))
add("pink-noise-60s", "pink-noise", "mono", "noise", "none", synth / "pink-noise.flac", None,
    "generated pink noise, amplitude 0.003 (about -50 dBFS)")

manifest = json.dumps({"version": 1, "items": items}, indent=1, ensure_ascii=False) + "\n"
(FIX / "manifest.json").write_text(manifest)
if not REPO_MANIFEST.exists() or REPO_MANIFEST.read_text() != manifest:
    REPO_MANIFEST.write_text(manifest)
print(f"{len(items)} items, {sum(i['durationSeconds'] for i in items) / 60:.1f} min")
