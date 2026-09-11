#!/bin/bash
#  Bytecode VM tests (M53 thin slice).
#
#  Positive: assemble tests/vm/slice.asm and diff the VM's output against
#  the checked-in golden file - this is the validation path that has to
#  outlive the Ada backend (docs/bytecode-vm.md).
#  Negative: the loader/verifier must REJECT malformed images with a
#  diagnostic and a non-zero exit, never crash (docs/obc-image.md).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AEGIR_ROOT="${AEGIR_ROOT:-}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/alrrt}"
export TMPDIR="${TMPDIR:-/tmp}"

VM="$ROOT/vm/bin/vm_main"
ASM="$ROOT/tools/obc_asm.py"
fails=0

note() { echo "run_vm: $*"; }
bad() { echo "run_vm: FAIL: $*" >&2; fails=$((fails + 1)); }

note "building the host VM"
if ! ( cd "$ROOT" && make vm-host AEGIR_ROOT="$AEGIR_ROOT" >"$WORK/build.log" 2>&1 ); then
   echo "run_vm: host VM build failed" >&2
   tail -20 "$WORK/build.log" >&2
   exit 1
fi

#  ---- positive: golden output --------------------------------------------
python3 "$ASM" "$ROOT/tests/vm/slice.asm" "$WORK/slice.obc" >/dev/null || \
   { echo "run_vm: assembly failed" >&2; exit 1; }
if timeout 60 "$VM" "$WORK/slice.obc" >"$WORK/slice.out" 2>"$WORK/slice.err"; then
   if ! diff -u "$ROOT/tests/vm/slice.out" "$WORK/slice.out"; then
      bad "slice output differs from tests/vm/slice.out"
   else
      note "positive: slice.asm output matches the golden file"
   fi
else
   bad "slice.asm did not run: $(cat "$WORK/slice.err")"
fi

#  ---- positive: the emitter's own encoder --------------------------------
#  bc_emit builds, through O2c_BC, the program slice.asm hand-assembles.
#  Same golden output, so this checks the encoder (offsets, pool layout,
#  jump resolution) against the interpreter it feeds.
if timeout 60 "$ROOT/vm/bin/bc_emit" "$WORK/emitted.obc" >"$WORK/emit.log" 2>&1; then
   if timeout 60 "$VM" "$WORK/emitted.obc" >"$WORK/emitted.out" 2>"$WORK/emitted.err"; then
      if ! diff -u "$ROOT/tests/vm/slice.out" "$WORK/emitted.out"; then
         bad "bc_emit output differs from tests/vm/slice.out"
      else
         note "positive: bc_emit (O2c_BC.Encode) output matches the golden file"
      fi
   else
      bad "bc_emit image did not run: $(cat "$WORK/emitted.err")"
   fi
else
   bad "bc_emit failed: $(cat "$WORK/emit.log")"
fi

#  ---- negative: malformed images must be rejected -------------------------
python3 - "$WORK" <<'PY'
import struct, sys, os
work = sys.argv[1]
base = open(os.path.join(work, "slice.obc"), "rb").read()
#  the code section, so byte searches below cannot hit a header byte
n_sec = struct.unpack_from("<H", base, 12)[0]
code_off = code_len = None
for i in range(n_sec):
    sid, _fl, off, size = struct.unpack_from("<IIQQ", base, 64 + 24 * i)
    if sid == 6:
        code_off, code_len = off, size
assert code_off and code_off > 64
code_end = code_off + code_len

def find_code(needle, start=None):
    at = base.find(needle, code_off if start is None else start, code_end)
    assert at > 0, needle
    return at

def put(name, data, needle):
    open(os.path.join(work, name), "wb").write(data)
    open(os.path.join(work, name + ".want"), "w").write(needle)

b = bytearray(base); b[0:4] = b"XXXX"
put("badmagic.obc", bytes(b), "bad magic")

b = bytearray(base); struct.pack_into("<H", b, 6, 1)      # future minor
put("futurever.obc", bytes(b), "unsupported image version")

b = bytearray(base); struct.pack_into("<Q", b, 40, len(base) + 8)
put("badsize.obc", bytes(b), "truncated or inconsistent image")

#  a jump target past the end of the code payload: patch the JZ operand
b = bytearray(base)
i = find_code(bytes([0xA1]))                              # JZ
struct.pack_into("<I", b, i + 1, 0xFFFFFF)
put("badjump.obc", bytes(b), "jump target")

#  An opcode the slice does not implement: rewrite the HALT to CALL.  The
#  search must start after the procedure table, because the table's own
#  n_procs is 1 - searching from the payload start patched the table and
#  relied on the loader rejecting a bogus procedure count, which is a
#  malformed image (Bad_Size) rather than an unimplemented opcode.
b = bytearray(base)
n_procs = struct.unpack_from("<I", b, code_off)[0]
body = code_off + 4 + n_procs * 24                        # first instruction
b[body] = 0xF1    # a reserved opcode: never implemented, so this contract
                  # cannot be retired by a feature the way LOAD_IDX_I and the
                  # REAL literal program were.
put("notimpl.obc", bytes(b), "not implemented")

#  native arity mismatch: CALL_NATIVE Out.Ln with one argument
b = bytearray(base)
i = find_code(bytes([0xC3, 0x02, 0x00, 0x00]))            # Out.Ln, 0 args
b[i + 3] = 1
put("badnative.obc", bytes(b), "bad native call")
PY

for img in badmagic futurever badsize badjump notimpl badnative; do
   want="$(cat "$WORK/$img.obc.want")"
   if timeout 60 "$VM" "$WORK/$img.obc" >"$WORK/$img.out" 2>"$WORK/$img.err"; then
      bad "$img was accepted but must be rejected"
   elif ! grep -aq "$want" "$WORK/$img.err"; then
      bad "$img: expected diagnostic containing '$want', got: $(cat "$WORK/$img.err")"
   else
      note "negative: $img rejected ($want)"
   fi
done

#  ---- positive: a hand-assembled procedure call --------------------------
#  add(a, b) returns a + b and the body passes 40 and 2, so the output is 42.
#  Assembled rather than emitted, so the interpreter is checked against
#  something that is not the emitter - the only way to exercise CALL until
#  the front end emits procedures.
if python3 "$ASM" "$ROOT/tests/vm/call.asm" "$WORK/call.obc" >/dev/null \
   && timeout 60 "$VM" "$WORK/call.obc" >"$WORK/call.out" 2>"$WORK/call.err"; then
   if diff -u "$ROOT/tests/vm/call.out" "$WORK/call.out"; then
      note "positive: call.asm (procedure call) matches the golden output"
   else
      bad "call.asm output differs from tests/vm/call.out"
   fi
else
   bad "call.asm did not run: $(cat "$WORK/call.err" 2>/dev/null)"
fi

#  ---- positive: a hand-assembled FOR loop ---------------------------------
#  Exercises FOR_ENTER_I/FOR_NEXT_I independently of the emitter: the loop
#  variable and its two hidden slots, the increment, the range test and the
#  exit, printing 1 through 5.
if python3 "$ASM" "$ROOT/tests/vm/for.asm" "$WORK/for.obc" >/dev/null \
   && timeout 60 "$VM" "$WORK/for.obc" >"$WORK/for.out" 2>"$WORK/for.err"; then
   if diff -u "$ROOT/tests/vm/for.out" "$WORK/for.out"; then
      note "positive: for.asm (FOR loop) matches the golden output"
   else
      bad "for.asm output differs from tests/vm/for.out"
   fi
else
   bad "for.asm did not run: $(cat "$WORK/for.err" 2>/dev/null)"
fi

#  ---- positive: hand-assembled SET operations -----------------------------
#  Exercises 0x3D-0x44 independently of the emitter: union, equality and
#  membership, printing 0, 1, 1, 0.
if python3 "$ASM" "$ROOT/tests/vm/set.asm" "$WORK/set.obc" >/dev/null \
   && timeout 60 "$VM" "$WORK/set.obc" >"$WORK/set.out" 2>"$WORK/set.err"; then
   if diff -u "$ROOT/tests/vm/set.out" "$WORK/set.out"; then
      note "positive: set.asm (SET operations) matches the golden output"
   else
      bad "set.asm output differs from tests/vm/set.out"
   fi
else
   bad "set.asm did not run: $(cat "$WORK/set.err" 2>/dev/null)"
fi

#  ---- positive: hand-assembled REAL arithmetic ---------------------------
#  Exercises 0x80-0x8B and LOAD_CONST_R independently of the emitter:
#  1.5 + 2.5 == 4.0, printing 1.
if python3 "$ASM" "$ROOT/tests/vm/real.asm" "$WORK/real.obc" >/dev/null \
   && timeout 60 "$VM" "$WORK/real.obc" >"$WORK/real.out" 2>"$WORK/real.err"; then
   if diff -u "$ROOT/tests/vm/real.out" "$WORK/real.out"; then
      note "positive: real.asm (REAL arithmetic) matches the golden output"
   else
      bad "real.asm output differs from tests/vm/real.out"
   fi
else
   bad "real.asm did not run: $(cat "$WORK/real.err" 2>/dev/null)"
fi

#  ---- positive: hand-assembled indexed access -----------------------------
#  Exercises LOAD_ADDR_G/LOAD_IDX_I/STORE_IDX_I independently of the emitter:
#  four globals stand in for an array, 42 goes into a[2] through its address
#  and is read back, printing 42.
if python3 "$ASM" "$ROOT/tests/vm/array.asm" "$WORK/array.obc" >/dev/null \
   && timeout 60 "$VM" "$WORK/array.obc" >"$WORK/array.out" 2>"$WORK/array.err"; then
   if diff -u "$ROOT/tests/vm/array.out" "$WORK/array.out"; then
      note "positive: array.asm (indexed access) matches the golden output"
   else
      bad "array.asm output differs from tests/vm/array.out"
   fi
else
   bad "array.asm did not run: $(cat "$WORK/array.err" 2>/dev/null)"
fi

#  ---- positive: hand-assembled record field access -------------------------
#  Exercises LOAD_FLD_I/STORE_FLD_I independently of the emitter: two globals
#  stand in for a two-field record, 42 goes into the field at offset 8 and is
#  read back, printing 42.
if python3 "$ASM" "$ROOT/tests/vm/rec.asm" "$WORK/rec.obc" >/dev/null \
   && timeout 60 "$VM" "$WORK/rec.obc" >"$WORK/rec.out" 2>"$WORK/rec.err"; then
   if diff -u "$ROOT/tests/vm/rec.out" "$WORK/rec.out"; then
      note "positive: rec.asm (record field access) matches the golden output"
   else
      bad "rec.asm output differs from tests/vm/rec.out"
   fi
else
   bad "rec.asm did not run: $(cat "$WORK/rec.err" 2>/dev/null)"
fi

#  ---- positive: hand-assembled NIL ----------------------------------------
#  Exercises LOAD_CONST_P independently of the emitter: a global is set to NIL
#  through a pool word of zero and compared against NIL, printing 1.  The half
#  of pointers that does not need the heap.
if python3 "$ASM" "$ROOT/tests/vm/nil.asm" "$WORK/nil.obc" >/dev/null \
   && timeout 60 "$VM" "$WORK/nil.obc" >"$WORK/nil.out" 2>"$WORK/nil.err"; then
   if diff -u "$ROOT/tests/vm/nil.out" "$WORK/nil.out"; then
      note "positive: nil.asm (pointer constants) matches the golden output"
   else
      bad "nil.asm output differs from tests/vm/nil.out"
   fi
else
   bad "nil.asm did not run: $(cat "$WORK/nil.err" 2>/dev/null)"
fi

#  ---- positive: hand-assembled ALLOC_NEW ----------------------------------
#  Exercises the TYPES descriptor and the arena independently of the emitter:
#  an object is allocated zeroed at the size the descriptor gives, 42 is
#  stored into its offset-8 field through the pointer and read back.
if python3 "$ASM" "$ROOT/tests/vm/new.asm" "$WORK/new.obc" >/dev/null \
   && timeout 60 "$VM" "$WORK/new.obc" >"$WORK/new.out" 2>"$WORK/new.err"; then
   if diff -u "$ROOT/tests/vm/new.out" "$WORK/new.out"; then
      note "positive: new.asm (allocation) matches the golden output"
   else
      bad "new.asm output differs from tests/vm/new.out"
   fi
else
   bad "new.asm did not run: $(cat "$WORK/new.err" 2>/dev/null)"
fi

#  ---- positive: hand-assembled linked list ---------------------------------
#  Exercises LOAD_FLD_P/STORE_FLD_P independently of the emitter: two records
#  are allocated, 42 goes into the first, the second links to it through its
#  pointer field, and 42 is read back by following the link.
if python3 "$ASM" "$ROOT/tests/vm/list.asm" "$WORK/list.obc" >/dev/null \
   && timeout 60 "$VM" "$WORK/list.obc" >"$WORK/list.out" 2>"$WORK/list.err"; then
   if diff -u "$ROOT/tests/vm/list.out" "$WORK/list.out"; then
      note "positive: list.asm (pointer fields) matches the golden output"
   else
      bad "list.asm output differs from tests/vm/list.out"
   fi
else
   bad "list.asm did not run: $(cat "$WORK/list.err" 2>/dev/null)"
fi

if [ "$fails" -gt 0 ]; then
   echo "run_vm: FAIL ($fails)" >&2
   exit 1
fi
echo "run_vm: PASS"
