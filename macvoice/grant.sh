#!/bin/sh
# Clears macvoice's stale permission entries and opens the Accessibility pane so you can re-add it.
# Only needed once, after the identity fix. Rebuilds no longer break the grant.
cd "$(dirname "$0")"
pkill -f 'macvoice.app/Contents/MacOS/macvoice' 2>/dev/null
tccutil reset Accessibility local.macvoice 2>/dev/null || echo "(no existing entry to clear)"
echo "Now: remove any old 'macvoice' row with the − button, then + and add:"
echo "  $(pwd)/macvoice.app"
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
