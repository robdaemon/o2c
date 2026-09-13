#!/bin/bash
#  Bytecode backend tests (M53): Oberon-2 source through the emitter to
#  the VM, diffed against checked-in golden output - the validation path
#  that has to outlive the Ada backend (docs/bytecode-vm.md).
#
#  Also checks the slice's contract: a construct the backend cannot yet
#  express must FAIL the compile with a clear message, never produce a
#  wrong image.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AEGIR_ROOT="${AEGIR_ROOT:-}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/alrrt}"
export TMPDIR="${TMPDIR:-/tmp}"

FRONT="$ROOT/tools/bin/o2c_bc_host"
VM="$ROOT/vm/bin/vm_main"
fails=0

note() { echo "run_bc: $*"; }
bad() { echo "run_bc: FAIL: $*" >&2; fails=$((fails + 1)); }

note "building the host front end and the VM"
if ! ( cd "$ROOT" && make tools-host vm-host AEGIR_ROOT="$AEGIR_ROOT" >"$WORK/build.log" 2>&1 ); then
   echo "run_bc: host build failed" >&2
   tail -20 "$WORK/build.log" >&2
   exit 1
fi

#  ---- positives: source -> image -> VM output vs golden -------------------
for name in sum ifelsif vmgreet proc local repeat case for set real arr rec ptr newt list recmix strch recreal outchar ext nested impderef fnexpr openarr typetest withguard typeguard dispatch newloop deepcall gcloop gcscalar ffi unops loopexit relops forstep fordown ptrfld ptrfield longarith arrparam boolops nobody filesintr lenopen nestedarr longfield; do
   src="$ROOT/tests/bc/$name.ob2"
   gold="$ROOT/tests/bc/$name.out"
   if ! timeout 120 "$FRONT" "$src" "$WORK/$name.obc" >"$WORK/$name.compile" 2>&1; then
      bad "$name: compile failed: $(cat "$WORK/$name.compile")"
      continue
   fi
   if ! timeout 60 "$VM" "$WORK/$name.obc" >"$WORK/$name.out" 2>"$WORK/$name.err"; then
      bad "$name: run failed: $(cat "$WORK/$name.err")"
      continue
   fi
   if ! diff -u "$gold" "$WORK/$name.out"; then
      bad "$name: VM output differs from $name.out"
   else
      note "positive: $name.ob2 matches the golden output"
   fi
done

#  ---- the slice's contract: unsupported source must not emit ------------
if timeout 120 "$FRONT" "$ROOT/tests/bc/unsupported.ob2" "$WORK/unsup.obc" \
   >"$WORK/unsup.log" 2>&1
then
   bad "unsupported.ob2 compiled, but the slice cannot express it"
else
   #  Any clear refusal will do: what the contract asserts is that the
   #  backend says so loudly, not the precise wording of the message.  It
   #  used to insist on "bytecode backend:" because the construct under it
   #  was ARRAY OF CHAR; that now works, and what replaced it is refused by
   #  the type parser instead, which is just as loud.
   if grep -aq 'o2c error:' "$WORK/unsup.log"; then
      note "negative: unsupported construct rejected ($(cat "$WORK/unsup.log"))"
   else
      bad "unsupported.ob2 failed without a clear diagnostic: $(cat "$WORK/unsup.log")"
   fi
fi

#  ---- the FOR step -------------------------------------------------------
#  `by` must be a non-zero integer constant.  The zero case is not pedantry:
#  a zero step never advances the loop variable, so the loop would not
#  terminate.  The variable case is the rule that was there before - only the
#  evidence moved from the step's SPELLING to its VALUE, so it is asserted
#  here to show the relaxation was not a free-for-all.
#  (Both used to be one check: the text of the step had to be digits, which
#  also refused `by -1` and so made a descending loop unwritable.)
for fcase in 'zero|by 0|must not be zero' \
             'varstep|by s|must be an integer constant'; do
   fl="${fcase%%|*}"; rest="${fcase#*|}"; fby="${rest%%|*}"; fmsg="${rest##*|}"
   printf 'module FB;\nvar i, s: integer;\nbegin s := 2; for i := 1 to 9 %s do end end FB.\n' \
      "$fby" > "$WORK/fb.ob2"
   if timeout 120 "$FRONT" "$WORK/fb.ob2" "$WORK/fb.obc" >"$WORK/fb.log" 2>&1
   then
      bad "$fl: FOR $fby compiled, but it is not a usable step"
   elif grep -aq "$fmsg" "$WORK/fb.log"; then
      note "negative: FOR $fby refused ($fmsg)"
   else
      bad "$fl: FOR $fby failed for the wrong reason: $(cat "$WORK/fb.log")"
   fi
done
#  The VM must report exhaustion rather than corrupt itself.  Before the
#  collector was fixed it freed the live list and returned a wrong answer,
#  which is indistinguishable from success without this check.
if timeout 120 "$FRONT" "$ROOT/tests/bc/gclive.ob2" "$WORK/glive.obc" \
   >"$WORK/glive.compile" 2>&1
then
   if timeout 120 "$VM" "$WORK/glive.obc" >"$WORK/glive.out" 2>"$WORK/glive.err"
   then
      bad "gclive.ob2 ran to completion, but its live set exceeds the arena"
   else
      if grep -aq 'heap exhausted' "$WORK/glive.err" "$WORK/glive.out"; then
         note "negative: live set larger than the arena reported as exhaustion"
      else
         bad "gclive.ob2 failed without reporting exhaustion: $(cat "$WORK/glive.err")"
      fi
   fi
else
   bad "gclive.ob2 did not compile: $(cat "$WORK/glive.compile")"
fi

#  ---- Threads.Start, with a procedure value and with a name ---------------
#  The point of the procedure type: Start takes a procedure *value*, so the
#  thread body may be chosen at run time by assigning to the variable.
#  Every fixture that has a golden is compiled, run and compared.  Discovered
#  rather than listed: a list is complete only until someone adds a fixture and
#  forgets the list, and this one had already fallen behind - thirty-four
#  fixtures with goldens were being compiled and never executed.  The golden is
#  the contract, so a fixture's presence in the directory is what enrols it.
#  Fixtures *without* a golden are compile-only or negative, and keep their own
#  explicit checks below; sorted for a stable order and stable output.
for SRC in $(ls "$ROOT"/tests/bc/*.out | sort); do
   TN="$(basename "${SRC%.out}")"
   if ! timeout 120 "$FRONT" "$ROOT/tests/bc/$TN.ob2" "$WORK/$TN.obc" \
        >"$WORK/$TN.compile" 2>&1; then
      bad "$TN.ob2 did not compile: $(cat "$WORK/$TN.compile")"
   elif ! timeout 60 "$VM" "$WORK/$TN.obc" >"$WORK/$TN.out" 2>"$WORK/$TN.err"
   then
      bad "$TN.ob2 failed to run: $(cat "$WORK/$TN.err")"
   elif diff -u "$ROOT/tests/bc/$TN.out" "$WORK/$TN.out" >/dev/null; then
      note "positive: $TN.ob2 compiles, runs, and prints the golden"
   else
      bad "$TN.ob2 output differs: $(cat "$WORK/$TN.out")"
   fi
done

#  A thread's entry must fit what a procedure value can name: parameterless
#  and resultless.  Rejected at compile time rather than discovered as a body
#  reading parameters it was never given.
for BN in threadstart_bad procval_bad; do
   if timeout 120 "$FRONT" "$ROOT/tests/bc/$BN.ob2" "$WORK/$BN.obc" \
        >"$WORK/$BN.log" 2>&1
   then
      bad "$BN.ob2 compiled, but it names a procedure that cannot be a value"
   else
      if grep -aq 'take' "$WORK/$BN.log"; then
         note "negative: $BN.ob2 rejected for taking arguments"
      else
         bad "$BN.ob2 failed without the expected diagnostic: $(cat "$WORK/$BN.log")"
      fi
   fi
done

#  A mutex must be module-level: the VM names it by its globals slot, and a
#  local has none.  Refused rather than silently becoming a global of its own.
if timeout 120 "$FRONT" "$ROOT/tests/bc/threadmutex_bad.ob2" "$WORK/mmb.obc" \
   >"$WORK/mmb.log" 2>&1
then
   bad "threadmutex_bad.ob2 compiled, but a local mutex has no slot to name"
else
   if grep -aq 'module-level variable' "$WORK/mmb.log"; then
      note "negative: a local mutex is refused"
   else
      bad "threadmutex_bad.ob2 failed without a clear diagnostic: $(cat "$WORK/mmb.log")"
   fi
fi

#  ---- calling a procedure value, end to end ------------------------------
#  Compiling is not enough here: the value has to reach the call.  The first
#  cut pushed the procedure id and never stored it, so the variable kept the
#  zeroed slot and the call went to procedure 0 - which compiles cleanly and
#  fails only at run time.
if ! timeout 120 "$FRONT" "$ROOT/tests/bc/proccall.ob2" "$WORK/pcall.obc" \
   >"$WORK/pcall.compile" 2>&1; then
   bad "proccall.ob2 did not compile: $(cat "$WORK/pcall.compile")"
elif ! timeout 60 "$VM" "$WORK/pcall.obc" >"$WORK/pcall.out" 2>"$WORK/pcall.err"
then
   bad "proccall.ob2 failed to run: $(cat "$WORK/pcall.err")"
elif diff -u "$ROOT/tests/bc/proccall.out" "$WORK/pcall.out" >/dev/null; then
   note "positive: proccall.ob2 calls a procedure value and prints the golden"
else
   bad "proccall.ob2 output differs: $(cat "$WORK/pcall.out")"
fi

#  ---- procedure types: the minimal form, and its refusal -----------------
#  A procedure type with no parameters and no result: a value is a procedure
#  id with no environment, which is what makes it cheap.  Parameter lists are
#  refused by name rather than mis-parsed.
if timeout 120 "$FRONT" "$ROOT/tests/bc/proctype.ob2" "$WORK/pt.obc" \
   >"$WORK/pt.log" 2>&1
then
   note "positive: proctype.ob2 (a PROCEDURE type) compiles"
else
   bad "proctype.ob2 did not compile: $(cat "$WORK/pt.log")"
fi

if timeout 120 "$FRONT" "$ROOT/tests/bc/proctype_bad2.ob2" "$WORK/ptb2.obc" \
   >"$WORK/ptb2.log" 2>&1
then
   bad "proctype_bad2.ob2 compiled, but a PROCEDURE target takes only a procedure name"
else
   if grep -aq 'is not a same-typed variable' "$WORK/ptb2.log"; then
      note "negative: non-procedure assigned to a PROCEDURE target rejected"
   else
      bad "proctype_bad2.ob2 failed without the expected diagnostic: $(cat "$WORK/ptb2.log")"
   fi
fi

if timeout 120 "$FRONT" "$ROOT/tests/bc/proctype_bad.ob2" "$WORK/ptb.obc" \
   >"$WORK/ptb.log" 2>&1
then
   bad "proctype_bad.ob2 compiled, but parameterised procedure types are not supported"
else
   if grep -aq 'procedure types with parameters' "$WORK/ptb.log"; then
      note "negative: parameterised procedure type rejected by name"
   else
      bad "proctype_bad.ob2 failed without a clear diagnostic: $(cat "$WORK/ptb.log")"
   fi
fi

#  ---- foreign modules: EXTERN binds, and an unknown symbol is rejected ---
#  A foreign module is an ordinary Oberon module - it has a body - whose
#  procedures bind to C symbols instead of having Oberon bodies.
if timeout 120 "$FRONT" "$ROOT/tests/bc/stubok.ob2" "$WORK/stubok.obc" \
   >"$WORK/stubok.log" 2>&1
then
   note "positive: stubok.ob2 (EXTERN binding) compiles"
else
   bad "stubok.ob2 did not compile: $(cat "$WORK/stubok.log")"
fi

#  A symbol the VM does not know must be a build error naming it, not a call
#  to whatever native id happens to sit nearby.
if timeout 120 "$FRONT" "$ROOT/tests/bc/stubbad.ob2" "$WORK/stubbad.obc" \
   >"$WORK/stubbad.log" 2>&1
then
   bad "stubbad.ob2 compiled, but its symbol is not a VM foreign function"
else
   if grep -aq 'no foreign function named' "$WORK/stubbad.log"; then
      note "negative: unknown EXTERN symbol rejected by name"
   else
      bad "stubbad.ob2 failed without naming the symbol: $(cat "$WORK/stubbad.log")"
   fi
fi

if [ "$fails" -gt 0 ]; then
   echo "run_bc: FAIL ($fails)" >&2
   exit 1
fi
echo "run_bc: PASS"
