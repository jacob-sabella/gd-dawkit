#!/usr/bin/env bash
# Run dawkit's checks headless. Exits non-zero on any failure or script error.
set -uo pipefail
cd "$(dirname "$0")/.."
# The native core first: its classes are in the class cache only once it is built.
tools/build_native.sh || { echo "test.sh: the native core did not build" >&2; exit 1; }
# The class cache has to exist before a script can name DawKit* classes.
godot --headless --path . --import >/dev/null 2>&1
LOG="$(mktemp)"
godot --headless --path . --script tests/run_tests.gd >"$LOG" 2>&1
RC=$?
grep -E 'FAIL|checks, |SCRIPT ERROR|Parse Error' -A2 "$LOG"
if grep -q 'SCRIPT ERROR' "$LOG"; then RC=1; fi
rm -f "$LOG"
exit $RC
