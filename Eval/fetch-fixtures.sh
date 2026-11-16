#!/usr/bin/env bash
# Downloads the public CC BY sources (sha256 pinned), sets up the scoring venv and builds the fixtures.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
EVAL=${MINUTIA_EVAL_DIR:-$HERE/../.eval}
FIX=${MINUTIA_EVAL_FIXTURES:-$EVAL/fixtures}
TOOLS=${MINUTIA_EVAL_TOOLS:-$EVAL/tools}
AMI=https://groups.inf.ed.ac.uk/ami
FLEURS=https://huggingface.co/datasets/google/fleurs/resolve/70bb2e84b976b7e960aa89f1c648e09c59f894dd/data
LIBRI=https://huggingface.co/datasets/openslr/librispeech_asr/resolve/71cacbfb7e2354c4226d01e70d77d5fca3d04ba1
LEADERBOARD=https://raw.githubusercontent.com/huggingface/open_asr_leaderboard/c21a412f2dd7cbe3af658d69fbf3d0dd536a264e/normalizer

SOURCES="
abb4917719c6e033b066fbd400b6d37fe46ddd62c89b513f77016a51f54e2ad1 ES2004a.Headset-0.wav $AMI/AMICorpusMirror/amicorpus/ES2004a/audio/ES2004a.Headset-0.wav
9be8e84e4ef93ea7eef669470cd6db017856f38f7321e0054199ad7393a1199c ES2004a.Headset-1.wav $AMI/AMICorpusMirror/amicorpus/ES2004a/audio/ES2004a.Headset-1.wav
a4f2f8ea7d965ede2c010e36bfc31c14c7792d07419bd5bc9519c8ddd1c8bc28 ES2004a.Headset-2.wav $AMI/AMICorpusMirror/amicorpus/ES2004a/audio/ES2004a.Headset-2.wav
5b3cf59816d5160d77ff00315dc7f6db816c175edb65e0d61691679fae633572 ES2004a.Headset-3.wav $AMI/AMICorpusMirror/amicorpus/ES2004a/audio/ES2004a.Headset-3.wav
634f42207e488b0eab3b34a81ff16d565705f8fc5e37be7cc3c3b56617ae3257 IS1009a.Headset-0.wav $AMI/AMICorpusMirror/amicorpus/IS1009a/audio/IS1009a.Headset-0.wav
db98d175dda0d07613795c715667a72b99c5372aabd14ee4dcb94d1fa9c273ee IS1009a.Headset-1.wav $AMI/AMICorpusMirror/amicorpus/IS1009a/audio/IS1009a.Headset-1.wav
9e28bfd55727b07d6a6020b7bf2797d113b35c69a1a3ad25cc4150be0937bf28 IS1009a.Headset-2.wav $AMI/AMICorpusMirror/amicorpus/IS1009a/audio/IS1009a.Headset-2.wav
7a0b041ad2f2cd9af1c8fcee08e598d6d88bd8f77a3174d7eb9e281a30ca0413 IS1009a.Headset-3.wav $AMI/AMICorpusMirror/amicorpus/IS1009a/audio/IS1009a.Headset-3.wav
b56e5babb2496b8795deeeda7e71178d7fbc9963f94276cf2a3f4b56ebbc9f9d ami_public_manual_1.6.2.zip $AMI/AMICorpusAnnotations/ami_public_manual_1.6.2.zip
055b6ddecc9ad493d9ead86babe3ebe225148dd3c174fa6f95cb83a4f9586e18 fleurs-de_de-dev.tsv $FLEURS/de_de/dev.tsv
92beded0999347ad5b8599fe70940e2e7b9232c67c426defb258e596ade94f48 fleurs-ja_jp-dev.tsv $FLEURS/ja_jp/dev.tsv
72cac13bbddbddf674d8102a9e7b90a3b1db5d777ed92e88eccc5ae69cb8fc9d fleurs-de_de-dev.tar.gz $FLEURS/de_de/audio/dev.tar.gz
2547f19203e1272aeba99c2235326fea525d6cfb9348bafbea2c3a7929e8e441 fleurs-ja_jp-dev.tar.gz $FLEURS/ja_jp/audio/dev.tar.gz
7113aa4c3cf963fb54697145719a7725f984c8836d1c494a554cbb9f1a017df0 ls-test-clean.parquet $LIBRI/clean/test/0000.parquet
38e0c86a8104585c577badd707ca4331e20fa2c645f46180af0b7bcdecff9249 ls-test-other.parquet $LIBRI/other/test/0000.parquet
"

mkdir -p "$FIX/raw" "$TOOLS/normalizer"
echo "$SOURCES" | while read -r sha name url; do
  [ -z "$sha" ] && continue
  file="$FIX/raw/$name"
  if [ ! -f "$file" ] || ! echo "$sha  $file" | shasum -a 256 -c --status; then
    echo "fetching $name"
    curl -fL --retry 3 -o "$file" "$url"
    echo "$sha  $file" | shasum -a 256 -c --status || { echo "checksum mismatch: $name"; exit 1; }
  fi
done

unzip -oq "$FIX/raw/ami_public_manual_1.6.2.zip" 'words/ES2004a.*' 'words/IS1009a.*' \
  corpusResources/meetings.xml LICENCE.txt -d "$FIX/ami-ann"

if [ ! -x "$TOOLS/venv/bin/python" ]; then
  python3 -m venv "$TOOLS/venv"
  "$TOOLS/venv/bin/pip" install -q jiwer==4.0.0 regex==2026.11.15 pyarrow==26.0.1 numpy==2.5.5
fi
for f in normalizer.py english_abbreviations.py; do
  [ -f "$TOOLS/normalizer/$f" ] || curl -fsL -o "$TOOLS/normalizer/$f" "$LEADERBOARD/$f"
done
echo "from .normalizer import EnglishTextNormalizer, BasicMultilingualTextNormalizer" > "$TOOLS/normalizer/__init__.py"

"$TOOLS/venv/bin/python" -I "$HERE/build_fixtures.py" "$FIX" "$HERE/manifest.json"
