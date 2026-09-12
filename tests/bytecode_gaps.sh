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
check "inline array type"  ok 'module G5; var v: array 4 of integer; begin end G5.' 
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

#  An imported builtin's exported procedure is an FFI primitive.  These used
#  to compile, run and silently do nothing; they now either work or refuse.
#  Convert.ToInt is the one that works - it is the shape the rest follow, so
#  this asserts a real converted value rather than merely that it compiles.
cat > "$WORK/ffi.ob2" <<'EOB'
module FFI;
import Convert, Out;
var s: array 8 of char;
    x: integer;
    v: real;
    r: integer;
begin
  s := "42";
  Convert.ToInt(s, x, r);
  Out.Int(x, 0); Out.Ln;
  s := "2.5";
  Convert.ToReal(s, v, r);
  Out.Real(v, 0); Out.Ln;
  x := 1234;
  Convert.FromInt(x, s);
  Out.String(s); Out.Ln
end FFI.
EOB
if timeout 60 "$FRONT" "$WORK/ffi.ob2" "$WORK/ffi.obc" >"$WORK/ffi.log" 2>&1; then
   got="$(timeout 60 "$ROOT"/vm/bin/vm_main "$WORK/ffi.obc" 2>/dev/null | tr -d '\n\r')"
   if [ "$got" = "422.5001234" ]; then
      note "  ok  Convert ToInt/ToReal/FromInt convert (42, 2.500, 1234)"
   else
      bad "the Convert trio printed '$got', expected 422.5001234"
   fi
else
   bad "Convert.ToInt no longer compiles: $(tail -1 "$WORK/ffi.log")"
fi

#  Files.Delete has a real side effect, so it is asserted by its EFFECT rather
#  than by output: create a file, delete it from bytecode, check it is gone.
#  A golden cannot express this - the program prints the same thing whether or
#  not the delete happened, which is exactly the silent no-op this replaced.
DFILE="$WORK/o2c_delme.txt"
printf 'doomed\n' > "$DFILE"
cat > "$WORK/del.ob2" <<EOB
module Del;
import Files, Out;
var s: array 64 of char;
begin
  s := "$DFILE";
  Files.Delete(s);
  Out.Int(1, 0); Out.Ln
end Del.
EOB
if timeout 60 "$FRONT" "$WORK/del.ob2" "$WORK/del.obc" >"$WORK/del.log" 2>&1; then
   got="$(timeout 60 "$ROOT"/vm/bin/vm_main "$WORK/del.obc" 2>/dev/null | tr -d '\n\r')"
   if [ "$got" = "1" ] && [ ! -e "$DFILE" ]; then
      note "  ok  Files.Delete removed the file (effect verified)"
   elif [ -e "$DFILE" ]; then
      bad "Files.Delete ran but the file is still there"
   else
      bad "the Files.Delete probe printed '$got', expected 1"
   fi
else
   bad "Files.Delete no longer compiles: $(tail -1 "$WORK/del.log")"
fi

#  Files.Rename, same contract: asserted by its effect.
RFROM="$WORK/o2c_from.txt"
RTO="$WORK/o2c_to.txt"
printf 'payload\n' > "$RFROM"
rm -f "$RTO"
cat > "$WORK/ren.ob2" <<EOB
module Ren;
import Files, Out;
var a: array 64 of char;
    b: array 64 of char;
begin
  a := "$RFROM";
  b := "$RTO";
  Files.Rename(a, b);
  Out.Int(1, 0); Out.Ln
end Ren.
EOB
if timeout 60 "$FRONT" "$WORK/ren.ob2" "$WORK/ren.obc" >"$WORK/ren.log" 2>&1; then
   got="$(timeout 60 "$ROOT"/vm/bin/vm_main "$WORK/ren.obc" 2>/dev/null | tr -d '\n\r')"
   if [ "$got" = "1" ] && [ ! -e "$RFROM" ] && [ -e "$RTO" ]; then
      note "  ok  Files.Rename moved the file (effect verified)"
   else
      bad "Files.Rename did not move the file (from:$([ -e "$RFROM" ] && echo y || echo n) to:$([ -e "$RTO" ] && echo y || echo n))"
   fi
else
   bad "Files.Rename no longer compiles: $(tail -1 "$WORK/ren.log")"
fi

#  Env.Get / Env.Set.  Asserted as a round trip AND as a read of a variable the
#  VM did not set, because the two together are what show it reaches the real
#  environment rather than a private table the natives keep to themselves.
cat > "$WORK/env.ob2" <<'EOB'
module EnvT;
import Env, Out;
var k: array 64 of char;
    v: array 64 of char;
begin
  k := "O2C_GAPS_ROUNDTRIP";
  v := "hello";
  Env.Set(k, v);
  v := "x";
  Env.Get(k, v);
  Out.String(v); Out.Ln;
  k := "O2C_GAPS_PREEXISTING";
  v := "x";
  Env.Get(k, v);
  Out.String(v); Out.Ln
end EnvT.
EOB
if timeout 60 "$FRONT" "$WORK/env.ob2" "$WORK/env.obc" >"$WORK/env.log" 2>&1; then
   got="$(O2C_GAPS_PREEXISTING=fromhost timeout 60 "$ROOT"/vm/bin/vm_main \
            "$WORK/env.obc" 2>/dev/null | tr -d '\n\r')"
   if [ "$got" = "hellofromhost" ]; then
      note "  ok  Env.Set/Get round-trips and reads a foreign variable"
   else
      bad "Env round-trip printed '$got', expected hellofromhost"
   fi
else
   bad "Env.Get/Set no longer compiles: $(tail -1 "$WORK/env.log")"
fi

#  Args.Get.  Needs the driver to forward a program argument, which is why
#  vm_main now accepts anything after the image.  Both directions are asserted:
#  a real argument is read, and an index past the end reports -1.
cat > "$WORK/args.ob2" <<'EOB'
module ArgsT;
import Args, Out;
var b: array 64 of char;
    r: integer;
begin
  Args.Get(1, b, r);
  Out.String(b); Out.Int(r, 0); Out.Ln;
  Args.Get(9, b, r);
  Out.Int(r, 0); Out.Ln
end ArgsT.
EOB
if timeout 60 "$FRONT" "$WORK/args.ob2" "$WORK/args.obc" >"$WORK/args.log" 2>&1; then
   got="$(timeout 60 "$ROOT"/vm/bin/vm_main "$WORK/args.obc" hello 2>/dev/null \
            | tr -d '\n\r')"
   if [ "$got" = "hello0-1" ]; then
      note "  ok  Args.Get reads a forwarded argument and rejects a bad index"
   else
      bad "Args.Get printed '$got', expected hello0-1"
   fi
else
   bad "Args.Get no longer compiles: $(tail -1 "$WORK/args.log")"
fi

#  XYplane.  Dot and Clear are only observable through IsDot, so all four are
#  asserted together - and IsDot is the first thing here to return a value,
#  which is what makes it the probe for the expression path as well.
cat > "$WORK/plane.ob2" <<'EOB'
module PlaneT;
import XYplane, Out;
var i: integer;
begin
  i := 0;
  if XYplane.IsDot(99, 99) then i := i + 1 end;
  Out.Int(i, 0); Out.Ln;
  XYplane.Open;
  XYplane.Dot(10, 20, 0);
  i := 0;
  if XYplane.IsDot(10, 20) then i := i + 10 end;
  if XYplane.IsDot(99, 99) then i := i + 1 end;
  Out.Int(i, 0); Out.Ln;
  XYplane.Clear;
  i := 0;
  if XYplane.IsDot(10, 20) then i := i + 100 end;
  Out.Int(i, 0); Out.Ln
end PlaneT.
EOB
if timeout 60 "$FRONT" "$WORK/plane.ob2" "$WORK/plane.obc" >"$WORK/plane.log" 2>&1; then
   got="$(timeout 60 "$ROOT"/vm/bin/vm_main "$WORK/plane.obc" 2>/dev/null \
            | tr -d '\n\r')"
   #  got has its newlines stripped: the three lines are 0 (never opened),
   #  10 (set) and 0 (cleared).
   if [ "$got" = "0100" ]; then
      note "  ok  XYplane Dot/Clear/IsDot verified through IsDot"
   else
      bad "XYplane printed '$got', expected 0, 10 and 0 (unopened/set/cleared)"
   fi
else
   bad "XYplane no longer compiles: $(tail -1 "$WORK/plane.log")"
fi

if [ "$fails" -eq 0 ]; then
   note "PASS (all listed gaps still as recorded)"
   exit 0
fi
note "FAIL: $fails entries differ from the recorded list"
exit 1
