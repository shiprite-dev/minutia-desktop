# minutia-eval

Head-to-head speech-to-text eval: on-device Parakeet (FluidAudio, Core ML) against Groq `whisper-large-v3-turbo`,
on the same audio. It is a developer tool, never part of CI, and the normal app build and `make test` never download a model.

```bash
Eval/fetch-fixtures.sh                     # once: sha256-pinned public audio, scoring venv, fixtures + manifest.json
export GROQ_API_KEY=...                    # required for a passing gate; groq-turbo is skipped without it
export OPENROUTER_API_KEY=...              # optional; hosted Parakeet Ultra (informational) is skipped without it
Eval/run-eval.sh                           # build (Release), run every engine, score
ENGINES="parakeet-v3" Eval/run-eval.sh     # subset
```

Requires Xcode, XcodeGen 2.46+, `ffmpeg`/`ffprobe` (`brew install ffmpeg`), Python 3, and `yt-dlp` or `uvx` (the
real-meeting fixtures run `uvx yt-dlp@2026.10.26` when `yt-dlp` is not on the PATH).

Everything lands in the gitignored `.eval/` folder at the repo root: `fixtures/`, `models/`, `tools/` (scoring
venv and normalizer), `DerivedData/` and `results/` (one `transcribe-<engine>.json` per engine,
`prepare-<engine>.json` per local model, `results.json`, `report.md`). Point any of them elsewhere with
`MINUTIA_EVAL_DIR`, or individually with `MINUTIA_EVAL_FIXTURES`, `MINUTIA_EVAL_MODELS`, `MINUTIA_EVAL_TOOLS`,
`MINUTIA_EVAL_RESULTS`, `MINUTIA_EVAL_DERIVED`.

`run-eval.sh` exits non-zero when a gated engine (`parakeet-v3`, `parakeet-ultra`) is missing or any gate fails:
no item errors, read English WER at most 12, conversational WER at most 20 and within 3 points of an error-free
Groq run, at least 20x realtime per channel on the full meeting, peak extra RAM under 2 GB, silence yields no
speech, the English then Japanese splice and every Japanese clip trip the quality guard, and every segment has
finite timings.

## Code and model boundary

- Swift (`minutia-eval`, target in `project.yml`) owns audio decoding, engine calls, wall-clock timing, process
  memory (`phys_footprint` peak via `task_info`), and the quality-guard windows. It compiles the app's own
  `Minutia/Sources/Transcribe` files, so the engine under test is the shipping one. Each engine runs in its own
  process so memory peaks do not mix.
- Python (`score.py`) owns normalization, WER/CER, aggregation, gates and the report. It never calls a model.
- The models only produce hypotheses. Every number in the report is computed by code from those hypotheses and
  the committed references in `manifest.json`.

## Scoring

- English WER: Open ASR Leaderboard `EnglishTextNormalizer` (Whisper's English normalizer: lowercase, punctuation
  stripped, numbers and spellings standardized, whitespace collapsed). German: `BasicMultilingualTextNormalizer`
  with diacritics kept. The same normalizer runs on reference and hypothesis for every engine.
- AMI hesitations (`um`, `uh`, `mm-hmm`, `hmm`, ...) are removed from reference and hypothesis alike.
- Error rates are micro-averaged (total edits over total reference words) per engine, class and channel.
- Japanese: CER after NFKC with punctuation, symbols and spaces removed. Informational only.
- Speed: audio seconds over wall seconds per file, including decode. Gate uses the 17.5 minute full meeting per channel.

## Fixtures (`manifest.json`, sources in `ATTRIBUTION.md`)

| Class                  | Content                                                                                                                                                                                        |
| ---------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| read-clean, read-other | 10 + 10 LibriSpeech utterances, evenly spaced over the sorted ids                                                                                                                              |
| conversational         | two 5 minute AMI excerpts; me = the talker with most words, them = sum of the other headsets, peak normalized; each headset gated to its own talk spurts so bleed does not count as insertions |
| conversational-echo    | me with them mixed in at -20 dB and 80 ms delay (reusable by the server echo test)                                                                                                             |
| meeting-full           | the whole ES2004a meeting as me/them, for speed, memory and guard calibration                                                                                                                  |
| de, ja                 | 10 FLEURS German and 5 Japanese dev clips                                                                                                                                                      |
| spliced                | 30 s English then 30 s Japanese; must trip the quality guard                                                                                                                                   |
| silence, noise         | 60 s digital silence and 60 s pink noise at about -50 dBFS; must yield no speech                                                                                                               |
| real-meeting-en, real-meeting-ja | informational: an 18 minute excerpt of a real English staff meeting and a 21 minute excerpt of a Japanese briefing with Q&A, both CC BY YouTube recordings, mono mixes (the browser-recording case); references are the uploaders' manual captions, never auto captions; the decoded audio is sha256 pinned |
