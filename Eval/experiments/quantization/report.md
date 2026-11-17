# Q4 quantization eval (2026-11-17)

Ultra 4-bit: not safe (k-means palette g16 +0.9 read, +0.9 conv, +1.5 de, +1.6 meeting-full WER; int4 per-block hits Core ML prediction timeouts).
Ultra 6-bit palette (enzolabs encoder, 425 MB vs 595 MB int8): read 1.47, conv 16.31, de 3.0, meeting-full 9.31, real-meeting-en 11.80, equal to the shipped int8 within noise.
Pro: int8 only; 4-bit not evaluated.
ovos Japanese ladder (own infer.py pipeline): real-ja CER fp16 24.59, int8 25.15, 6-bit 24.27, 4-bit 21.96, all worse than the shipped FluidInference parakeet-ja at 15.04.
Trap: FluidAudio 0.18.2 AsrModels.load re-downloads the pinned revision unless the folder has a matching .fluidaudio-revision marker.
Scripts: scripts/, raw results: results/<variant>/.
