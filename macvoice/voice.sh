#!/bin/sh
# Starts voice mode and shows its output. Ctrl-C stops watching; `./voice.sh stop` quits it.
# Args are passed through, e.g. ./voice.sh --live
cd "$(dirname "$0")"
MATCH='macvoice.app/Contents/MacOS/macvoice'

pkill -f "$MATCH" 2>/dev/null
# Wait for it to actually die. `open` re-activates a still-running instance instead of
# relaunching it, which silently drops the arguments (that is what ate --live).
i=0
while pgrep -f "$MATCH" >/dev/null 2>&1 && [ $i -lt 50 ]; do
  /bin/sleep 0.1
  i=$((i + 1))
done
pgrep -f "$MATCH" >/dev/null 2>&1 && pkill -9 -f "$MATCH" 2>/dev/null && /bin/sleep 0.3

[ "$1" = "stop" ] && { echo "stopped"; exit 0; }

: > macvoice.log
open -a "$(pwd)/macvoice.app" --args "$@"

# Confirm it really started with the flags we asked for.
i=0
while [ ! -s macvoice.log ] && [ $i -lt 50 ]; do /bin/sleep 0.1; i=$((i + 1)); done
if ! pgrep -f "$MATCH" >/dev/null 2>&1; then
  echo "macvoice did not start. Log:"; cat macvoice.log; exit 1
fi
echo "voice mode started${*:+ with: $*}. Ctrl-C stops watching, the app keeps running."
echo "quit it with: ./voice.sh stop"
echo "---"
tail -f macvoice.log
