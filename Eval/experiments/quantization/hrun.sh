#!/usr/bin/env bash
# usage: hrun.sh <variant> <encoder mlmodelc src>
Q=/Volumes/Mango/tmp/minutia-eval-q4; v=$1; export TMPDIR=$Q/work
df -h / | tail -1 | awk '{print $4}' | grep -q Gi || { echo LOWDISK; exit 1; }
mkdir -p $Q/results/$v
/Volumes/Mango/Developer/DerivedData/MinutiaEval/Build/Products/Release/minutia-eval transcribe --engine parakeet-ultra --models $Q/work/m-$v --fixtures /Volumes/Mango/tmp/minutia-eval-fixtures --out $Q/results/$v/transcribe-parakeet-ultra.json > $Q/work/h-$v.log 2>&1
cmp $Q/work/m-$v/parakeet-ultra/Encoder.mlmodelc/weights/weight.bin $2/weights/weight.bin && echo "$v weights intact"
