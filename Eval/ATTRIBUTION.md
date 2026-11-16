# Eval fixture attribution

The eval downloads its audio at run time (`fetch-fixtures.sh`); no audio is committed. `manifest.json` carries the
reference transcripts, redistributed under the same licenses. Every source is licensed CC BY 4.0
(https://creativecommons.org/licenses/by/4.0/). Changes made: clips cut, resampled to 16 kHz mono FLAC, headsets
gated to each talker's own speech and summed into a "them" channel, mixes and splices as described per item in
`manifest.json`. Real-meeting references are the uploaders' manual captions with cue timing, speaker tags and sound
labels removed.

| Source                                                                              | Credit                                                                                                                      | Link                                                                                         |
| ----------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| LibriSpeech ASR corpus (test-clean, test-other)                                     | V. Panayotov, G. Chen, D. Povey, S. Khudanpur, "LibriSpeech: an ASR corpus based on public domain audio books", ICASSP 2015 | https://www.openslr.org/12 (mirror: https://huggingface.co/datasets/openslr/librispeech_asr) |
| AMI Meeting Corpus (ES2004a, IS1009a individual headsets; manual annotations 1.6.2) | AMI Consortium, University of Edinburgh                                                                                     | https://groups.inf.ed.ac.uk/ami/corpus/license.shtml                                         |
| FLEURS (de_de, ja_jp dev)                                                           | A. Conneau et al., "FLEURS: Few-shot Learning Evaluation of Universal Representations of Speech", 2022, Google              | https://huggingface.co/datasets/google/fleurs                                                |
| "Interpretation of Staff Meeting" (YouTube dmFENp1-lcM, 0 to 18 min, audio and manual English captions) | CATIE Center | https://www.youtube.com/watch?v=dmFENp1-lcM |
| "Civictech Accelerator Program 1st Batch エントリー説明会" (YouTube FrrrtE9HNOA, 30 to 51 min, audio and manual Japanese captions) | Code for Japan | https://www.youtube.com/watch?v=FrrrtE9HNOA |

Text normalization uses the Open ASR Leaderboard normalizer (Apache 2.0), fetched at a pinned commit:
https://github.com/huggingface/open_asr_leaderboard/tree/c21a412f2dd7cbe3af658d69fbf3d0dd536a264e/normalizer
