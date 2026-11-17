# Code-switch transcription eval (English and Japanese in one meeting)

Turn language comes from construction. Each hypothesis segment is assigned to the turn containing its timestamp midpoint (a 0.15 s grace into the following gap). EN turns: WER with the Open ASR English normalizer (hesitations stripped). JA turns: CER after NFKC with punctuation, symbols and spaces removed. Missed % = share of reference words (EN) or characters (JA) in turns whose hypothesis is empty or in the wrong script (under 50% Japanese-script characters for JA turns, under 50% Latin letters for EN turns). x realtime = fixture audio seconds over wall seconds, including decode; best-of-two and oracle run both local engines, so their speed is audio over the sum of both wall times. Groq ran with `language` unset (Whisper auto-detect), as the harness sends no language field.

## codeswitch (612 s, 18 turns: 9 EN, 9 JA; 977 reference EN words, 1492 reference JA characters)

| Option | EN WER % | JA CER % | Missed EN % | Missed JA % | x realtime |
|---|---:|---:|---:|---:|---:|
| ultra | 21.7 | 99.6 | 0.0 | 100.0 | 49.4 |
| ja | 100.0 | 8.8 | 100.0 | 0.0 | 100.7 |
| best-of-two | 42.9 | 35.7 | 9.2 | 19.4 | 33.1 |
| oracle | 21.7 | 8.8 | 0.0 | 0.0 | 33.1 |
| groq | 63.2 | 42.6 | 41.5 | 17.0 | 217.6 |

Deleted share of reference units (speech dropped inside turns, not only wrong-script turns):

| Option | EN deleted % | JA deleted % |
|---|---:|---:|
| ultra | 5.9 | 50.3 |
| ja | 95.4 | 3.4 |
| best-of-two | 32.3 | 27.1 |
| oracle | 5.9 | 3.4 |
| groq | 57.1 | 15.3 |

Best-of-two window choices (30 s guard windows, higher meanConfidence wins): 11 ultra, 10 ja of 21.

## codeswitch_fast (302 s, 51 turns: 26 EN, 25 JA; 343 reference EN words, 982 reference JA characters)

| Option | EN WER % | JA CER % | Missed EN % | Missed JA % | x realtime |
|---|---:|---:|---:|---:|---:|
| ultra | 36.7 | 108.4 | 7.0 | 100.0 | 47.1 |
| ja | 100.0 | 20.2 | 100.0 | 0.9 | 84.1 |
| best-of-two | 98.3 | 20.2 | 94.2 | 0.9 | 30.2 |
| oracle | 36.7 | 20.2 | 7.0 | 0.9 | 30.2 |
| groq | 100.0 | 42.9 | 97.1 | 16.9 | 161.9 |

Deleted share of reference units (speech dropped inside turns, not only wrong-script turns):

| Option | EN deleted % | JA deleted % |
|---|---:|---:|
| ultra | 13.7 | 77.3 |
| ja | 100.0 | 8.4 |
| best-of-two | 98.3 | 8.4 |
| oracle | 13.7 | 8.4 |
| groq | 86.9 | 35.0 |

Best-of-two window choices (30 s guard windows, higher meanConfidence wins): 1 ultra, 10 ja of 11.

## Method notes and caveats

- Best-of-two uses the harness guard windows, which are 30 s (QualityGuard.windowSeconds), not 15 s. A window takes all segments of the engine with the higher duration-weighted mean token confidence, so in the fast variant (4 to 8 s turns) most windows hold both languages and one engine must lose the other language's speech.
- Oracle takes each segment from the engine matching the language of the turn its midpoint falls in (ultra for EN turns, ja for JA turns). It is the ceiling for any per-segment router, not for a per-window one.
- Segment-midpoint assignment is coarse: a hypothesis segment spanning a turn boundary is credited wholly to one turn, which moves errors between turns. This matters most in the fast variant and for Groq, whose segments can cover up to 30 s.
- References are the uploaders' manual captions, cut at caption boundaries. Caption timing drifts by a fraction of a second, captions clean up fillers and false starts and the English captions have speaker labels (stripped here); the Japanese captions are loose paraphrases in places. Absolute error rates therefore carry a floor, so compare options, not absolute values.
- Segments are turn-ordered text per turn, so a hypothesis that reorders text across turns cannot be repaired. Parakeet ja was run on both fixtures because their manifest language is en+ja.
