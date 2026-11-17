# Language-routed code-switch transcription (ultra vs ja)

Same fixtures and Parakeet transcripts as report.md (no re-transcription). Scoring identical to report.md: segment midpoint decides the turn, EN WER with the Open ASR normalizer, JA CER after NFKC, missed = share of reference units in turns whose hypothesis is empty or in the wrong script. LID acc = share of decisions whose engine matches the true language of the unit's midpoint: per VAD chunk for the heuristic and LID rows, per overlap cluster for the z-pick, per 30 s window (majority turn language) for best-of-two.

## codeswitch

184 VAD chunks (2 to 6 s), true-language purity 99.8% of audio seconds.

| Option | EN WER % | JA CER % | Missed EN % | Missed JA % | LID acc % | Extra cost |
|---|---:|---:|---:|---:|---:|---|
| oracle | 21.7 | 8.8 | 0.0 | 0.0 | 100.0 | none (runs both engines) |
| best-of-two (30 s) | 42.9 | 35.7 | 9.2 | 19.4 | 66.7 | none (runs both engines) |
| per-segment z-pick | 26.5 | 8.8 | 0.0 | 0.0 | 94.1 (34 contested of 96 clusters) | none (runs both engines) |
| script heuristic | 30.6 | 40.6 | 0.0 | 0.0 | 52.2 | none (runs both engines); ultra conf < p25 of EN calibration |
| LID whisper-tiny | 22.3 | 10.0 | 0.0 | 0.0 | 98.4 (98.0 by seconds) | 1.39 s CPU per audio min plus both engines |
| LID whisper-base | 22.4 | 10.0 | 0.0 | 0.0 | 96.7 (96.9 by seconds) | 2.57 s CPU per audio min plus both engines |
| LID ecapa | 22.1 | 8.8 | 0.0 | 0.0 | 98.9 (99.3 by seconds) | 1.67 s CPU per audio min plus both engines |

## codeswitch_fast

90 VAD chunks (2 to 6 s), true-language purity 93.4% of audio seconds.

| Option | EN WER % | JA CER % | Missed EN % | Missed JA % | LID acc % | Extra cost |
|---|---:|---:|---:|---:|---:|---|
| oracle | 36.7 | 20.2 | 7.0 | 0.9 | 100.0 | none (runs both engines) |
| best-of-two (30 s) | 98.3 | 20.2 | 94.2 | 0.9 | 90.9 | none (runs both engines) |
| per-segment z-pick | 40.5 | 21.1 | 24.8 | 0.9 | 92.3 (13 contested of 61 clusters) | none (runs both engines) |
| script heuristic | 36.7 | 33.8 | 7.0 | 9.9 | 68.9 | none (runs both engines); ultra conf < p25 of EN calibration |
| LID whisper-tiny | 40.8 | 27.3 | 7.0 | 8.0 | 94.4 (94.8 by seconds) | 1.39 s CPU per audio min plus both engines |
| LID whisper-base | 40.8 | 20.9 | 7.0 | 1.9 | 94.4 (95.3 by seconds) | 2.57 s CPU per audio min plus both engines |
| LID ecapa | 36.7 | 28.7 | 7.0 | 9.9 | 98.9 (99.3 by seconds) | 1.67 s CPU per audio min plus both engines |

## Calibration (z-pick)

Per-model segment confidence on its matching-language single-language item from results-or2: ultra: n=203, mean 0.969, sd 0.057, p25 0.966; ja: n=120, mean 0.953, sd 0.079, p25 0.956. z = (segment confidence - mean) / sd; an overlap cluster (transitively time-overlapping ultra and ja segments) takes the engine with the higher duration-weighted mean z. Clusters with segments from one engine only keep them. Calibration audio is the same source video as the fixture turns (real-en-dmFENp1-lcM, real-ja-FrrrtE9HNOA), so z-pick sees in-distribution calibration.


## Model cost and portability

| Model | Size on disk | LID time per audio minute (CPU, this Mac, PyTorch fp32, includes mel and 30 s pad for whisper) | Core ML |
|---|---:|---:|---|
| whisper-tiny | 72 MB (fp16 checkpoint) | 1.39 s | Not converted by me. Whisper encoders have published Core ML exports (whisper.cpp and WhisperKit ship tiny and base); whether WhisperKit's language detection path covers this use was not checked. |
| whisper-base | 139 MB (fp16 checkpoint) | 2.57 s | Same as tiny. |
| speechbrain ecapa voxlingua107 | 93 MB (92 MB embedding model + 0.7 MB classifier) | 1.67 s | Not converted by me and I found no published export. Plausible via coremltools (conv1d, SE blocks, attentive statistics pooling), with fbank features computed outside the model; unverified. |

Timing is wall time over both fixtures (912 s of audio) after model load, one chunk per forward pass, no batching.

## Caveats

- Chunking is energy VAD. The fixtures have 0.3 s of digital silence between turns, which makes turn boundaries easy to find (purity 99.8% and 93.4% of seconds in the long and fast fixtures). Real meetings with overlapping or back-to-back speech will chunk worse, so the LID rows are optimistic on chunk purity.
- Routing is all or nothing per chunk. In the fast fixture one wrongly routed chunk costs about 8% of the JA characters, which is why ecapa (98.9% chunk accuracy) scores a worse JA CER than whisper-base (94.4%): which chunks fail matters more than how many.
- The z-pick calibration and the script-heuristic threshold (p25 of ultra confidence on real-en) use the same source videos as the fixtures, so they are in-distribution. Heuristic threshold and the 3-character kana floor were fixed in advance, not tuned.
- Small sample: 18 and 51 turns, two fixtures, one speaker pair per language. Differences of 1 to 2 points are not significant.
- LID ran on CPU PyTorch, not on the Neural Engine. Production cost on Core ML is untested.
