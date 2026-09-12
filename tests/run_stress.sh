#!/bin/bash
#  Scheduling stress (M62).
#
#  Why this exists: the other suites run at the production quantum, where a
#  thread almost always finishes inside one turn - so nothing exercises a
#  switch in the middle of an instruction sequence, which is exactly where
#  resumption bugs live.  This runs the whole of run_bc and run_vm at a
#  quantum of 1, where the VM takes the machine back after *every*
#  instruction, and at 2 and 3 to catch an off-by-one in the budget check
#  that 1 alone might miss.
#
#  No new goldens: a correct VM produces the same output at any quantum, so
#  the existing goldens are the oracle.  That is the whole claim being
#  tested - that where a switch lands cannot change what a program does.
#
#  The quantum comes from O2C_QUANTUM, read by the host driver, so nothing
#  here edits or rebuilds the source: an earlier version of this test patched
#  the constant and rebuilt, which is neither repeatable nor safe (a stale
#  binary tested the wrong thing twice in one night).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fails=0
note() { echo "run_stress: $*"; }
bad()  { echo "run_stress: FAIL: $*" >&2; fails=$((fails + 1)); }

for Q in 1 2 3; do
   for S in run_bc run_vm; do
      if O2C_QUANTUM="$Q" timeout 1200 "$ROOT/tests/$S.sh" >"$WORK/$S.$Q.log" 2>&1
      then
         note "quantum $Q: $S passes unchanged"
      else
         bad "quantum $Q: $S failed - a switch point changed what a program did"
         tail -25 "$WORK/$S.$Q.log" >&2
      fi
   done
done

if [ "$fails" -eq 0 ]; then
   note "PASS"
   exit 0
fi
note "FAIL: $fails suite run(s) disagreed with the goldens"
exit 1
