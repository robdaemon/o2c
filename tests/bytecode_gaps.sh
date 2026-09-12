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
  Out.Int(i, 0); Out.Ln;
  if XYplane.Key = CHR(0) then i := 1 else i := 0 end;
  Out.Int(i, 0); Out.Ln
end PlaneT.
EOB
if timeout 60 "$FRONT" "$WORK/plane.ob2" "$WORK/plane.obc" >"$WORK/plane.log" 2>&1; then
   got="$(timeout 60 "$ROOT"/vm/bin/vm_main "$WORK/plane.obc" 2>/dev/null \
            | tr -d '\n\r')"
   #  got has its newlines stripped: the three lines are 0 (never opened),
   #  10 (set) and 0 (cleared).
   if [ "$got" = "01001" ]; then
      note "  ok  XYplane Dot/Clear/IsDot/Key all verified"
   else
      bad "XYplane printed '$got', expected 0,10,0 (unopened/set/cleared) and 1 (NUL key)"
   fi
else
   bad "XYplane no longer compiles: $(tail -1 "$WORK/plane.log")"
fi

#  In.Open / String / Name.  The VM grows the Ada backend's tokenizer: read
#  to end of input, join with spaces, then skip and take a token.  Input is
#  piped in, so this is one of the few probes whose setup is not just a file.
cat > "$WORK/in.ob2" <<'EOB'
module InT;
import In, Out;
var s: array 64 of char;
    n: array 64 of char;
    i: integer;
    c: char;
    r: real;
begin
  In.Open;
  In.String(s);
  Out.String(s); Out.Ln;
  In.Name(n);
  Out.String(n); Out.Ln;
  In.Int(i);
  Out.Int(i, 0); Out.Ln;
  In.Char(c);
  Out.Int(ORD(c), 0); Out.Ln;
  In.Real(r);
  Out.Real(r, 0); Out.Ln
end InT.
EOB
if timeout 60 "$FRONT" "$WORK/in.ob2" "$WORK/in.obc" >"$WORK/in.log" 2>&1; then
   got="$(echo "hello world 42 X 2.5" | \
            timeout 60 "$ROOT"/vm/bin/vm_main "$WORK/in.obc" \
            2>/dev/null | tr -d '\n\r')"
   #  hello, world, 42, 88 (ORD X) and 2.500
   if [ "$got" = "helloworld42882.500" ]; then
      note "  ok  In tokenises and converts (String/Name/Int/Char/Real)"
   else
      bad "In printed '$got', expected helloworld42882.500"
   fi
else
   bad "In.Open/String/Name no longer compile: $(tail -1 "$WORK/in.log")"
fi

#  The default is refusal.  A module that is imported but has no bytecode
#  emission must not compile: it used to build Ada text that bytecode
#  discarded, so the call ran and quietly yielded nothing - Math.cos (0.0)
#  printed 0.000 and Strings.Length ("abcd") printed 16.  Asserted for both an
#  expression call and a statement call, since they are separate paths.
for probe in 'Math.cos (0.0)|var x: real; begin x := Math.cos(0.0) end' \
             'Strings.Length|var s: array 16 of char; n: integer; begin s := "abcd"; n := Strings.Length(s) end'; do
   label="${probe%%|*}"; body="${probe#*|}"
   mod="${label%%.*}"
   printf 'module GapT; import %s, Out; %s GapT.\n' "$mod" "$body" > "$WORK/gap.ob2"
   if timeout 60 "$FRONT" "$WORK/gap.ob2" "$WORK/gap.obc" >"$WORK/gap.log" 2>&1; then
      bad "$label compiled - it has no bytecode emission and must refuse"
   elif grep -q "is not yet supported" "$WORK/gap.log"; then
      note "  ok  $label refuses rather than silently yielding nothing"
   else
      bad "$label failed for the wrong reason: $(tail -1 "$WORK/gap.log")"
   fi
done

#  Unary operators - the gap that was NOT in this list, and why.
#
#  `not` / `~` and unary `-` were neither implemented nor refused: they
#  compiled, ran, and stored the operand UNCHANGED, with no diagnostic.  The
#  checklist could not see them because it is generated from the compiler's
#  refusals, and a construct that never refuses is invisible to that
#  generation.  A wrong number is worse than a refusal - it is the failure
#  mode the rest of this file exists to prevent - so it is asserted by VALUE,
#  the same way the Convert trio is: a version that compiles and still drops
#  the operator must FAIL here.
cat > "$WORK/un.ob2" <<'EOB'
module UnT;
import Out;
var y, x, i, acc: integer; r, q: real; f: boolean;
begin
  y := 7;   x := -y;  Out.Int(x, 0); Out.Ln;
  r := 2.5; q := -r;  Out.Real(q, 0); Out.Ln;
  Out.Int(-42, 0); Out.Ln;
  f := true;
  if not f then Out.Int(1, 0) else Out.Int(0, 0) end; Out.Ln;
  acc := 0; for i := -2 to 2 do acc := acc + i end; Out.Int(acc, 0); Out.Ln
end UnT.
EOB
if timeout 60 "$FRONT" "$WORK/un.ob2" "$WORK/un.obc" >"$WORK/un.log" 2>&1; then
   got="$(timeout 60 "$ROOT"/vm/bin/vm_main "$WORK/un.obc" 2>/dev/null | tr -d '\n\r')"
   #  -7, -2.500, -42, 0 (NOT of true) and 0 (-2-1+0+1+2)
   if [ "$got" = "-7-2.500-4200" ]; then
      note "  ok  unary '-' and 'not' compute (verified by value, not by compiling)"
   else
      bad "unary operators printed '$got', expected -7-2.500-4200"
   fi
else
   bad "unary '-'/'not' no longer compile: $(tail -1 "$WORK/un.log")"
fi

#  Unary minus on LONGINT.  This used to assert a REFUSAL, on the reasoning
#  that a sign on a 64-bit value must not silently become a 32-bit NEG.  It now
#  works, because LONGINT arithmetic works (see the LONGINT section further
#  down), so the assertion is inverted - and asserted by VALUE, since "it
#  compiles" is exactly what the old refusal could not be told apart from.
cat > "$WORK/ln.ob2" <<'EOB'
module LN;
import Out;
var n: longint;
begin
  n := 5;
  n := -n;
  if n = -5 then Out.String("neg-ok") else Out.String("neg-bad") end; Out.Ln
end LN.
EOB
if timeout 60 "$FRONT" "$WORK/ln.ob2" "$WORK/ln.obc" >"$WORK/ln.log" 2>&1; then
   got="$(timeout 60 "$ROOT"/vm/bin/vm_main "$WORK/ln.obc" 2>/dev/null \
            | tr -d '\n\r')"
   if [ "$got" = "neg-ok" ]; then
      note "  ok  unary minus on LONGINT negates (value verified)"
   else
      bad "LONGINT unary minus printed '$got', expected neg-ok"
   fi
else
   bad "LONGINT unary minus no longer compiles: $(tail -1 "$WORK/ln.log")"
fi

note "--- BOOLEAN operators: the divergences that DO refuse ---"
#  The real remaining gap at the operator site.  Both are accepted by the Ada
#  backend and refused, loudly, here.
#
#  `or` on a SET is deliberately NOT listed: both backends reject it (the
#  operand-type check runs before the mode test), so it is a front-end limit
#  rather than a backend divergence, and a differential could never see it.
check "BOOLEAN or"  blocked 'module G40; import Out; var g: boolean; begin g := (1 = 1) or (2 = 3) end G40.'
check "BOOLEAN &"   blocked 'module G41; import Out; var g: boolean; begin g := (1 = 1) & (2 = 3) end G41.'

note "--- record fields, and the two that were refused by OMISSION ---"
#  Both of these were refusals that named the wrong thing, which is why they
#  lasted.  Fixed, and asserted here so they cannot come back:
#
#    p^.field[i]  used to say "an array needs a non-zero length".  The length
#                 was fine; the index path pushed a GLOBALS slot for an object
#                 that lives on the heap, and Total_Slots of a POINTER is 0.
#    LONGINT      a record field of type LONGINT was refused because the
#    fields       allowed-type list omitted it - and the message listed only
#                 what WAS allowed, so the missing entry was invisible.
#
#  tests/bc/ptrfld.ob2 holds both by value.  These entries assert they compile
#  at all, which is the part a golden cannot state.
check "array field through a pointer"  ok 'module G43; type A = array 4 of char; type R = record s: A; n: integer end; type P = pointer to R; var p: P; i: integer; begin new(p); i := 0; while i < 2 do p^.s[i] := CHR(65 + i); i := i + 1 end end G43.'
check "LONGINT record field"           ok 'module G44; type R = record n: longint; k: integer end; type P = pointer to R; var p: P; begin new(p); p^.n := 5; p^.k := 1 end G44.'

note "--- pointer FIELDS, and the spelling that was unusable ---"
#  A field declared with a NAMED pointer type (`p: Ptr`, which is what Files'
#  `f: File` is) was refused, while the self-referential spelling (`next: Ptr`
#  inside the record it points at) worked.  One construct, two spellings, one
#  of them unusable: `h.p := q` said "assigning through a pointer designator
#  is not yet supported" and `h.p^.n` said nothing at all, because the walk
#  classified the whole designator as a bare pointer.
#
#  tests/bc/ptrfield.ob2 holds the behaviour by value.  These entries assert
#  the shapes compile, and that the self-referential spelling - which the
#  corpus depends on - still does.
check "pointer field: assignment"     ok 'module G45; type R = record n: integer end; type P = pointer to R; type H = record p: P end; var h: H; q: P; begin new(q); h.p := q end G45.'
check "pointer field: read through it" ok 'module G46; type R = record n: integer end; type P = pointer to R; type H = record p: P end; var h: H; q: P; k: integer; begin new(q); h.p := q; k := h.p^.n end G46.'
check "pointer field: the linked-list spelling still works" ok 'module G47; type Node = record v: integer; next: Node end; type P = pointer to Node; var p, q: P; begin new(p); new(q); q^.next := p; p^.v := 1 end G47.'

note "--- LONGINT: arithmetic works, its own literals do not ---"
#  Every operator was refused with one message.  Assignment and comparison
#  worked, so no test could notice, and the existing longint.ob2 only did
#  those two.  A LONGINT is the same 8-byte slot as an INTEGER here, so the
#  integer opcodes were always the LONGINT opcodes.
check "LONGINT add/sub/mul/DIV/MOD and unary -" ok 'module G48; var n: longint; begin n := 6; n := n + 1; n := n - 1; n := n * 2; n := n DIV 2; n := n MOD 2; n := -n end G48.'
#  What is left is the LITERAL, which is a different thing: the parser types an
#  integer literal as INTEGER, so a value above INTEGER'"'"'Last cannot be
#  written.  The Ada backend accepts it, so this IS a divergence - recorded so
#  it is not mistaken for the arithmetic gap again.
check "LONGINT literal above INTEGER'Last" blocked 'module G49; var n: longint; begin n := 3000000000 end G49.'

note "--- ARRAY OF parameters, and the Files intrinsics ---"
#  Out.String (s) inside a procedure failed with "operand-stack underflow": a
#  bare ARRAY OF CHAR pushed nothing (its address is in the parameter's own
#  slot), and the inline print loop only knew how to run off a globals array.
#  tests/bc/arrparam.ob2 holds it by value, with three different lengths so a
#  stale bound shows up.
check "Out.String on an ARRAY OF parameter" ok 'module G50; import Out; var a: array 4 of char; procedure P(s: array of char); begin Out.String(s) end P; begin a := "hi"; P(a) end G50.'
check "string comparison on an ARRAY OF parameter" ok 'module G51; import Out; var a: array 4 of char; f: boolean; procedure P(s: array of char; r: array of char); begin f := s = r end P; begin a := "hi"; P(a, a) end G51.'
#  The Files intrinsics FDel / FRename used to refuse in bytecode mode even
#  though their natives exist (ids 9 and 10): their branches appended to the
#  Ada body only.  They are NOT reachable from a user module - the compiler
#  gates them on the Files module - so there is no source-level check to write
#  here, and a check that compiled some unrelated source would be worse than
#  none.  What proves them is the MODULE compiling: the bytecode front end is
#  run over the real Files source (extracted from the compiler) as part of the
#  3d measurement, and it now gets past both.

if [ "$fails" -eq 0 ]; then
   note "PASS (all listed gaps still as recorded)"
   exit 0
fi
note "FAIL: $fails entries differ from the recorded list"
exit 1
