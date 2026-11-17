#!/usr/bin/env bash
# usage: sc.sh <variant|ultra> ; prints rows
Q=/Volumes/Mango/tmp/minutia-eval-q4; v=$1; D=$Q/results/sc-$v; rm -rf $D; mkdir -p $D
if [ $v = ultra ]; then cp /Volumes/Mango/tmp/minutia-eval-results-or2/transcribe-parakeet-ultra.json $D/; else cp $Q/results/$v/transcribe-parakeet-ultra.json $D/; fi
cp /Volumes/Mango/tmp/minutia-eval-results/prepare-parakeet-ultra.json $D/
/Volumes/Mango/tmp/minutia-eval-tools/venv/bin/python -I /Volumes/Mango/tmp/e29-eval-desktop/Eval/score.py /Volumes/Mango/tmp/minutia-eval-fixtures $D /Volumes/Mango/tmp/minutia-eval-tools >/dev/null 2>&1
echo "== $v"; grep -E "^\| parakeet-ultra \| (read|conversational|de|meeting-full|real-meeting-en|spliced|silence|noise) \| (all)" $D/report.md | grep -v echo | awk -F'|' '{printf "%s %s %s | ",$3,$6,$7} END{print ""}'
grep -A4 "^## Gates" $D/report.md | tail -1 | cut -c1-120
