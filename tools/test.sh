#!/usr/bin/env bash
# Run dawkit's checks headless. Exits non-zero on any failure or script error.
set -uo pipefail
cd "$(dirname "$0")/.."
# The class cache has to exist before a script can name DawKit* classes.
godot --headless --path . --import >/dev/null 2>&1
LOG="$(mktemp)"
godot --headless --path . --script tests/run_tests.gd >"$LOG" 2>&1
RC=$?
grep -E 'FAIL|checks, |SCRIPT ERROR|Parse Error' -A2 "$LOG"
if grep -q 'SCRIPT ERROR' "$LOG"; then RC=1; fi
rm -f "$LOG"
exit $RC
