#!/usr/bin/env bash
# usage: mkmodels.sh <variant> <encoder .mlmodelc dir>
Q=/Volumes/Mango/tmp/minutia-eval-q4; M=$Q/work/m-$1/parakeet-ultra; rm -rf $Q/work/m-$1; mkdir -p $M
for c in Decoder Preprocessor JointDecisionv3; do cp -cR $Q/compiled/enzo/$c.mlmodelc $M/; done
cp -cR $2 $M/Encoder.mlmodelc
cp $Q/work/pro-models/parakeet-ultra/{parakeet_v3_vocab.json,parakeet_vocab.json,config.json} $M/
printf '95eaa59a39d4394f047a4dc5cce480388a60d1b6\n' > $M/.fluidaudio-revision
