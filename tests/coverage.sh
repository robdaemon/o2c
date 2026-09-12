#!/bin/bash
#  Construct coverage: every token kind the lexer can produce must be
#  exercised by a fixture the BYTECODE backend actually runs.
#
#  Why this exists, and why it is not a grep.  A construct with no fixture
#  cannot be found by a differential: a construct no test uses cannot
#  disagree with anything.  The first pass at this was a grep over
#  tests/bc + samples + tests/vm and it reported that exactly two token
#  kinds went unexercised - `>=` and `or`.  Both halves of that were wrong:
#
#    * the hit counts came from files this backend never compiles.  `~`,
#      `loop`, `exit` and `by` all appear in samples/hello.ob2 (no test or
#      Makefile target compiles it), and tests/vm/*.asm is assembly whose
#      comments are full of keyword-shaped words.  The real number over
#      tests/bc is SEVEN, not two.
#    * a hit says nothing about whether the construct WORKS.  `not` and
#      unary `-` scored as covered while emitting no opcode at all, and
#      `loop`/`exit` scored as covered while compiling to a straight-line
#      block.  All three printed wrong numbers silently.
#
#  So the corpus is tests/bc - the fixtures run_bc.sh actually runs - and
#  the token kinds come from the LEXER, via tools/o2c_tokscan, rather than
#  from a pattern.  The lexer is the right oracle: it never sees a token
#  inside a comment, and it will not confuse `>=` with `>` followed by `=`.
#
#  This check answers ONE question: is each construct in front of the
#  backend at all.  Whether the backend gets it RIGHT is the differential's
#  job (see docs/bytecode-gaps.md), and the two are not substitutes.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/alrrt}"
export TMPDIR="${TMPDIR:-/tmp}"

TOKSCAN="$ROOT/tools/bin/o2c_tokscan"
FRONT="$ROOT/tools/bin/o2c_bc_host"
VM="$ROOT/vm/bin/vm_main"
fails=0

note() { echo "coverage: $*"; }
bad()  { echo "coverage: FAIL: $*" >&2; fails=$((fails + 1)); }

if [ ! -x "$TOKSCAN" ] || [ ! -x "$FRONT" ]; then
   ( cd "$ROOT" && make tools-host vm-host \
       AEGIR_ROOT="${AEGIR_ROOT:-}" >"$WORK/build.log" 2>&1 ) \
     || { tail -20 "$WORK/build.log" >&2; exit 1; }
fi

#  ---- the language's surface, taken from the lexer itself ----------------
#  Nothing here is typed out by hand, so the set cannot drift from the lexer:
#  a new token kind appears in this list the moment it is declared.
grep -o 'Tok_[A-Za-z_]*' "$ROOT/compiler/o2c_lexer.ads" \
  | sort -u | tr 'a-z' 'A-Z' > "$WORK/all.txt"

#  Not constructs: the scanner's own states, which no source can "use".
cat > "$WORK/exempt.txt" <<'EOB'
TOK_EOF
TOK_ERROR
EOB

timeout 120 "$TOKSCAN" "$ROOT"/tests/bc/*.ob2 | sort -u > "$WORK/seen.txt"

sort "$WORK/all.txt" > "$WORK/all.sorted"
comm -23 "$WORK/all.sorted" "$WORK/seen.txt" > "$WORK/unseen.txt"

note "=== corpus: tests/bc ($(ls "$ROOT"/tests/bc/*.ob2 | wc -l) fixtures) ==="
note "token kinds the lexer can produce: $(wc -l < "$WORK/all.sorted")"

#  ---- every unexercised kind must be a recorded known gap ----------------
#  The known-gap list is the escape hatch, and it is deliberately explicit:
#  a kind listed here is one we have DECIDED not to exercise yet, with the
#  reason and the probe that pins its current behaviour.  Anything else
#  going unexercised is a failure, which is what keeps this from decaying
#  into a list nobody updates.
known_gaps() {
   #  $1 = token kind
   grep -q "^$1\$" "$WORK/known.txt" 2>/dev/null
}

cat > "$WORK/known.txt" <<'EOB'
TOK_AND
EOB

while read -r kind; do
   [ -z "$kind" ] && continue
   if grep -q "^$kind\$" "$WORK/exempt.txt"; then
      note "  exempt    $kind (a scanner state, not a construct)"
   elif known_gaps "$kind"; then
      note "  known gap $kind (see the entries below)"
   else
      bad "$kind is produced by the lexer but no tests/bc fixture contains it"
   fi
done < "$WORK/unseen.txt"

while read -r kind; do
   grep -q "^$kind\$" "$WORK/unseen.txt" || \
      bad "$kind is listed as a known gap but IS now exercised - remove the entry"
done < "$WORK/known.txt"

#  ---- the known gaps, each pinned by a probe -----------------------------
#  A known gap has to say what it currently does, or it is just a comment.
#  These three are the constructs the coverage check found behind the old
#  "only two" claim: two refuse loudly, one is a hole in the grammar.

note "--- known gaps, pinned ---"

#  `or` and `&` are accepted by the Ada backend and refused, loudly, by this
#  one.  (Both need AND/OR opcodes; docs/obc-image.md has none.)
#  BOOLEAN or / & used to be listed here as known gaps - they refused loudly
#  ("BOOLEAN operators are not yet supported"), with no opcode in the spec to
#  emit.  They now have one (BAND 0x72, BOR 0x73, taken from the block the
#  spec reserved beside BEQ/BNE/BTEST), and tests/bc/boolops.ob2 is the value
#  fixture that exercises both TOKEN KINDS - which is also why TOK_AMP and
#  TOK_OR are no longer in the known-gap list above: coverage requires a
#  fixture, and there is one.
#
#  Asserted here by compiling and RUNNING, because the interesting failure for
#  this check is a token kind that is exercised but produces nothing.
cat > "$WORK/bandor.ob2" <<'EOB'
module BandOrG;
import Out;
var f: boolean;
begin
  f := (1 = 1) & (2 = 3);
  if f then Out.Int(0, 0) else Out.Int(1, 0) end; Out.Ln;
  f := (1 = 1) or (2 = 3);
  if f then Out.Int(2, 0) else Out.Int(0, 0) end; Out.Ln
end BandOrG.
EOB
if timeout 60 "$FRONT" "$WORK/bandor.ob2" "$WORK/bandor.obc" \
     >"$WORK/bandor.log" 2>&1; then
   got="$(timeout 60 "$ROOT"/vm/bin/vm_main "$WORK/bandor.obc" 2>/dev/null \
            | tr -d '\n\r')"
   if [ "$got" = "12" ]; then
      note "  ok  BOOLEAN & and or emit and compute (1 then 2)"
   else
      bad "BOOLEAN &/or printed '$got', expected 12"
   fi
else
   bad "BOOLEAN &/or no longer compile: $(tail -1 "$WORK/bandor.log")"
fi

#  `AND` is reserved by the lexer but never parsed - Parse_Simple/Term handle
#  Tok_Amp for `&`, and no code path reads Tok_And.  So the keyword spelling
#  is not a synonym for the operator: it is a syntax error.  Recorded rather
#  than fixed because `&` is the Oberon-2 spelling; the gap is that a
#  reserved word is unusable, not that an operator is missing.
cat > "$WORK/andk.ob2" <<'EOB'
module AndG;
var f: boolean;
begin f := (1 = 1) AND (2 = 3) end AndG.
EOB
if timeout 60 "$FRONT" "$WORK/andk.ob2" "$WORK/andk.obc" >"$WORK/andk.log" 2>&1; then
   bad "the AND keyword now parses - promote it to a fixture and drop this entry"
else
   note "  ok  TOK_AND  the reserved word AND still does not parse"
fi

#  There WAS a fourth entry here: descending FOR, pinned as a probe because
#  coverage cannot see it - its tokens (FOR, TO, BY, MINUS) are all exercised
#  by ascending loops, so the token check passed while the construct was
#  broken.  It has since been fixed (the BY header took the step's value
#  instead of scanning its text for digits) and is now held by
#  tests/bc/fordown.ob2, like any other working construct.
#
#  The entry is removed rather than rewritten because a value fixture is
#  strictly better evidence now that it is possible: the probe could only
#  assert that the body ran ZERO times, which is correct Oberon-2 for
#  `for i := 3 to 1` and was the thing mistaken for the gap in the first
#  place.  What was actually broken was `by -1`, and only a descent can
#  assert that.
#
#  The limitation itself stands: a construct that is fully covered AND wrong
#  is invisible here, and only the differential (3c) can see it.

if [ "$fails" -eq 0 ]; then
   note "PASS (every token kind is exercised, exempt, or a recorded known gap)"
   exit 0
fi
note "FAIL: $fails entries need attention"
exit 1
