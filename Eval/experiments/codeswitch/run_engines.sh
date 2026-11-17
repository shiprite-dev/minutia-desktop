#!/usr/bin/env bash
set -u
cd /Volumes/Mango/tmp/e29-eval-desktop
DD=/Volumes/Mango/tmp/minutia-eval-codeswitch/dd
R=/Volumes/Mango/tmp/minutia-eval-results-codeswitch
export TMPDIR=/Volumes/Mango/tmp/minutia-eval-codeswitch/tmp; mkdir -p $TMPDIR
BIN=$DD/Build/Products/Release/minutia-eval
eval "$(grep -E '^\s*export GROQ_API_KEY=' ~/.zshrc | head -1)"
for e in parakeet-ultra parakeet-ja; do
  $BIN transcribe --engine $e --models /Volumes/Mango/tmp/minutia-eval-models --fixtures /Volumes/Mango/tmp/minutia-eval-codeswitch/fixtures --out $R/transcribe-$e.json
done
echo ALLDONE
