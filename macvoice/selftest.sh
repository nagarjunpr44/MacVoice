#!/bin/sh
# Dictation is pure code (no Jev, no screen read): start phrase, verbatim typing, stop-phrase suffix, stop.
cd "$(dirname "$0")"
out=$(printf '%s\n' 'Start dictating.' 'Hello world.' 'the end, stop dictating' | ./macvoice --repl --dry-run --delay 0 2>&1)
for want in 'dictating: what you say' 'would type "Hello world."' 'would type "the end,"' 'dictation off'; do
  echo "$out" | grep -qF "$want" || { echo "$out"; echo "FAIL: missing: $want"; exit 1; }
done
echo "dictation ok"
