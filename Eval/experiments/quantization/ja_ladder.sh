#!/usr/bin/env bash
set -euo pipefail
Q=/Volumes/Mango/tmp/minutia-eval-q4; PY=$Q/venv/bin/python; FIX=/Volumes/Mango/tmp/minutia-eval-fixtures
export TMPDIR=$Q/work
for v in ${VARIANTS:-fp16 int8 6bit 4bit}; do
  $PY -I $Q/scripts/ja_run.py $Q/repos/ovos-ja-$v $Q/repos/ovos-ja-int8/infer.py $FIX/manifest.json $FIX $Q/results/ja-$v.json ALL 2>&1 | tee $Q/work/ja-$v.log
done
