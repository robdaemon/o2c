#!/bin/bash
#  Known gaps in the bytecode backend, as a re-runnable probe.
#
#  Each entry is a construct the *Ada* backend accepts and the bytecode backend
#  does not.  The script asserts the current state, so fixing a gap makes it
#  FAIL until the entry is removed - which is what a todo list should do, and
#  what a prose list cannot.
#
#  Why this exists: these were reported from a grep and an inference twice in
#  one session, and both times the inference was wrong.  A construct is listed
#  here only once a probe shows it failing, and the probe is the listing.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FRONT="$ROOT/tools/bin/o2c_bc_host"

export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/alrrt}"
export TMPDIR="${TMPDIR:-/tmp}"

fails=0
note() { echo "bytecode_gaps: $*"; }
bad()  { echo "bytecode_gaps: FAIL: $*" >&2; fails=$((fails + 1)); }

if [ ! -x "$FRONT" ]; then
   ( cd "$ROOT" && make tools-host >"$WORK/build.log" 2>&1 ) \
     || { tail -20 "$WORK/build.log" >&2; exit 1; }
fi

#  $1 label, $2 expected (blocked|ok), $3 source
check() {
   printf '%s\n' "$3" > "$WORK/p.ob2"
   if timeout 60 "$FRONT" "$WORK/p.ob2" "$WORK/p.obc" >"$WORK/p.log" 2>&1; then
      got=ok
   else
      got=blocked
   fi
   if [ "$got" = "$2" ]; then
      note "  $2  $1"
   else
      bad "$1 is $got, but this list says $2 - the list needs updating"
   fi
}

note "=== bytecode gaps, as of this commit ==="
check "ARRAY OF CHAR variable"  ok 'module G1; type T = array 8 of char; var v: T; begin end G1.'
check "ARRAY OF BOOLEAN variable"  ok 'module G2; type T = array 4 of boolean; var v: T; begin end G2.'
check "ARRAY OF REAL variable"  ok 'module G3; type T = array 4 of real; var v: T; begin end G3.'
check "ARRAY OF INTEGER variable" ok 'module G4; type T = array 4 of integer; var v: T; begin end G4.'
check "inline array type"       blocked 'module G5; var v: array 4 of integer; begin end G5.'
check "CONST in an expression"  ok 'module G6; import Out; const N = 3; var k: integer; begin k := N end G6.'
check "CONST, computed value"  ok 'module G6b; import Out; const N = 3 + 1; var k: integer; begin k := N end G6b.' 
check "SET operands (union, intersection, difference)"  ok 'module G31; import Out; var a: set; b: set; c: set; d: boolean; begin a := {1}; b := {2}; c := a + b; d := 2 in c end G31.' 
check "SET variable"  ok 'module G6; import Out; var v: set; b: boolean; begin v := {1, 3}; b := 3 in v end G6.' 
check "LONGINT declaration"    ok 'module G8; var n: longint; begin end G8.'
check "LONGINT assignment"  ok 'module G9; import Out; var n: longint; begin n := 5; if n = 5 then Out.Int(1,0) end end G9.' 
check "record, INTEGER field"   ok 'module G9; type R = record x: integer end; var v: R; begin end G9.'
check "record extension"        ok 'module G10; type A = record x: integer end; type B = record (A) y: integer end; var v: B; begin end G10.'
check "pointer"                 ok 'module G11; type R = record x: integer end; type P = pointer to R; var v: P; begin end G11.'
check "parameterless call"      ok 'module G12; procedure P; begin end P; begin P end G12.'


note "--- CHAR arrays and strings ---"
check "ARRAY OF CHAR variable"  ok 'module G20; type T = array 8 of char; var v: T; begin end G20.'
check "element store and load"  ok 'module G21; import Out; type T = array 8 of char; var v: T; c: char; begin c := "z"; v[2] := c; Out.Char(v[2]) end G21.'
check "string comparison"  ok 'module G24; import Out; type T = array 8 of char; var a: T; b: T; f: boolean; begin a := "x"; b := "y"; f := a < b end G24.'
check "Out.String on a CHAR array"  ok 'module G23; import Out; type T = array 8 of char; var v: T; begin v := "hi"; Out.String(v) end G23.'
check "string literal assign"   ok 'module G22; import Out; type T = array 8 of char; var v: T; begin v := "hi"; Out.Char(v[0]) end G22.'

if [ "$fails" -eq 0 ]; then
   note "PASS (all listed gaps still as recorded)"
   exit 0
fi
note "FAIL: $fails entries differ from the recorded list"
exit 1
