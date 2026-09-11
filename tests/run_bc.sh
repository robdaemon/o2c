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
for name in sum ifelsif vmgreet proc local repeat case for set real arr rec ptr newt list recmix strch recreal outchar ext nested impderef fnexpr openarr typetest withguard typeguard dispatch newloop deepcall gcloop gcscalar; do
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
   #  backend says so loudly, not the precise wording of the message.
   if grep -aq 'bytecode backend:' "$WORK/unsup.log"; then
      note "negative: unsupported construct rejected ($(cat "$WORK/unsup.log"))"
   else
      bad "unsupported.ob2 failed without a clear diagnostic: $(cat "$WORK/unsup.log")"
   fi
fi

#  ---- the collector's contract: a live set larger than the arena --------
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

if [ "$fails" -gt 0 ]; then
   echo "run_bc: FAIL ($fails)" >&2
   exit 1
fi
echo "run_bc: PASS"
