#!/usr/bin/env bash
Q=/Volumes/Mango/tmp/minutia-eval-q4; export TMPDIR=$Q/work/q
E=$Q/work/enzo/parakeet-ultra-coreml-greedy
for v in int4b32 pal4g16; do
  [ -d $Q/work/q/Encoder-$v.mlpackage ] || $Q/venv/bin/python -I $Q/scripts/quant.py $v $E/Encoder.mlpackage $Q/work/q/Encoder-$v.mlpackage > $Q/work/q-$v.log 2>&1
done
echo ALLDONE > $Q/work/q-done
