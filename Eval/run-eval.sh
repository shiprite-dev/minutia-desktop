#!/usr/bin/env bash
# Builds minutia-eval (Release), runs every engine over the fixtures in its own process, then scores.
# Groq runs only when GROQ_API_KEY is set; this script is never part of CI.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
EVAL=${MINUTIA_EVAL_DIR:-$ROOT/.eval}
FIX=${MINUTIA_EVAL_FIXTURES:-$EVAL/fixtures}
TOOLS=${MINUTIA_EVAL_TOOLS:-$EVAL/tools}
MODELS=${MINUTIA_EVAL_MODELS:-$EVAL/models}
OUT=${MINUTIA_EVAL_RESULTS:-$EVAL/results}
DERIVED=${MINUTIA_EVAL_DERIVED:-$EVAL/DerivedData}
ENGINES=${ENGINES:-parakeet-v3 parakeet-ultra parakeet-ja groq-turbo openrouter-parakeet-ultra}
export MINUTIA_EVAL_FIXTURES=$FIX MINUTIA_EVAL_TOOLS=$TOOLS
mkdir -p "$OUT" "$MODELS"
rm -f "$OUT"/transcribe-*.json

[ -f "$FIX/manifest.json" ] || "$ROOT/Eval/fetch-fixtures.sh"

cd "$ROOT"
xcodegen generate --quiet
xcodebuild -project Minutia.xcodeproj -scheme minutia-eval -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED" build CODE_SIGNING_ALLOWED=NO -quiet
BIN="$DERIVED/Build/Products/Release/minutia-eval"

for engine in $ENGINES; do
  if [ "$engine" = groq-turbo ]; then
    if [ -z "${GROQ_API_KEY:-}" ]; then echo "skipping groq-turbo: GROQ_API_KEY not set"; continue; fi
  elif [ "$engine" = openrouter-parakeet-ultra ]; then
    if [ -z "${OPENROUTER_API_KEY:-}" ]; then echo "skipping $engine: OPENROUTER_API_KEY not set"; continue; fi
  elif [ ! -f "$OUT/prepare-$engine.json" ]; then
    "$BIN" prepare --engine "$engine" --models "$MODELS" --out "$OUT/prepare-$engine.json"
  fi
  "$BIN" transcribe --engine "$engine" --models "$MODELS" --fixtures "$FIX" --out "$OUT/transcribe-$engine.json"
done

"$TOOLS/venv/bin/python" -I "$ROOT/Eval/score.py" "$FIX" "$OUT" "$TOOLS"
