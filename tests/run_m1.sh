#!/bin/sh
# o2c M1 regression: the full dogfood pipeline.
#
#   1. build o2c.elf (o2c runs under Aegir)
#   2. boot a test-mode initrd staging Tests/O2c; o2c reads the demo
#      module sources from the initrd (Tests/O2cLib/*.ob2), compiles
#      them as separate modules and prints each generated Ada unit
#      between markers; rebuild them all on the host
#   3. boot again staging Tests/Hello; assert the full demo output,
#      including the cross-module tail (Math exports)
#
# Requires AEGIR_ROOT (the aegir checkout; no default).
set -eu

: "${AEGIR_ROOT:?AEGIR_ROOT must point at the aegir checkout}"
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK="${TMPDIR:-/tmp}/o2c-m1"
QEMU_LOG="$WORK/boot.log"
RUN_MIN=${RUN_MIN:-280}

rm -rf "$WORK"; mkdir -p "$WORK"

cleanup() {
   pkill -f 'qemu-system-riscv6[4]' 2>/dev/null || true
}
trap cleanup EXIT INT TERM

boot_once() {  # $1 = extra make vars, $2 = marker
   rm -f "$QEMU_LOG"
   ( cd "$AEGIR_ROOT" && make run INITRD_MODE=min \
        O2C_ROOT="$ROOT" $1 QEMU_ARGS='-nographic -display none' \
        >"$QEMU_LOG" 2>&1 ) &
   local mp=$!
   local waited=0
   while [ "$waited" -lt "$RUN_MIN" ]; do
      sleep 5; waited=$((waited+5))
      grep -aq -- "$2" "$QEMU_LOG" && return 0
      kill -0 "$mp" 2>/dev/null || break
   done
   echo "run_m1: marker '$2' not seen in $RUN_MIN s (tail below)" >&2
   tail -5 "$QEMU_LOG" >&2 || true
   return 1
}

echo "run_m1: building o2c.elf"
#  build the Ada backend, the Aegir VM and the guest fixture image: the
#  min-mode initrd stages vm.elf as Tests/Vm and the fixture at
#  Tests/O2cBC/VmGreet.obc (see the aegir Makefile's O2C_VM_* vars).
make -C "$ROOT" build vm-aegir vm-fixture AEGIR_ROOT="$AEGIR_ROOT" >/dev/null

echo "run_m1: boot 1/2 - o2c compiles the demo modules (retry on torn capture)"
ATT=0
while [ "$ATT" -lt 6 ]; do
   ATT=$((ATT+1))
   echo "run_m1:   attempt $ATT"
   boot_once "" '--- ada end ---'
   python3 - "$QEMU_LOG" "$WORK" <<'PY'
import sys
log, work = sys.argv[1], sys.argv[2]
txt = open(log, errors="replace").read()
buf = {}
cur = None
for line in txt.splitlines():
    if line.startswith("--- unit ") and line.endswith(" ---"):
        cur = line[len("--- unit "):-len(" ---")]
        buf.setdefault(cur, [])
    elif line == "--- unit end ---":
        cur = None
    elif line.startswith("O2C|") and cur is not None:
        buf[cur].append(line[4:])
for name, lines in buf.items():
    open(work + "/" + name, "w").write("\n".join(lines) + "\n")
PY
   if [ ! -s "$WORK/hello.adb" ] || [ ! -s "$WORK/math.ads" ] \
      || [ ! -s "$WORK/math.adb" ] \
      || ! grep -q 'procedure Hello' "$WORK/hello.adb" \
      || ! grep -q 'package Math is' "$WORK/math.ads"; then
      echo "run_m1: capture torn (units missing/incomplete); retrying" >&2
      continue
   fi
   cp "$ROOT/tests/hello.gpr" "$WORK/"
   if ( cd "$AEGIR_ROOT/userspace/echo" && alr exec -- gprbuild -q -p \
        -P "$WORK/hello.gpr" -aP "$AEGIR_ROOT/userspace/rts" \
        -XAEGIR_ROOT="$AEGIR_ROOT" >/dev/null ); then
      break
   else
      echo "run_m1: host build of emitted Ada failed (torn capture); retrying" >&2
   fi
done
if [ "$ATT" -ge 6 ]; then
   echo "run_m1: emitted-Ada capture/build failed after 6 attempts" >&2
   exit 1
fi

echo "run_m1: boot 2/2 - assert hello output incl. shared O2c_Types"
echo "  exports (406) and the Files module reading the staged"
echo "  Tests/O2cLib/Sample.txt (M40)"
boot_once "O2C_HELLO_ELF=$WORK/bin/hello.elf" '406'
#  The boot-1 source capture also contains every string/number literal the
#  demo uses, so the demo assertions below must look at the runtime console
#  only - never at the O2C| capture lines.
RUNTIME_LOG="$WORK/boot_runtime.log"
grep -av '^O2C|' "$QEMU_LOG" > "$RUNTIME_LOG" || true

if ! grep -aq 'O2c files demo ok' "$RUNTIME_LOG"; then
   echo "run_m1: Files read demo output not seen in boot 2 (tail below)" >&2
   tail -30 "$RUNTIME_LOG" >&2
   exit 1
fi
if ! grep -aq 'O2cW!' "$RUNTIME_LOG"; then
   echo "run_m1: Files write demo (BD0: roundtrip) output not seen" >&2
   tail -30 "$RUNTIME_LOG" >&2
   exit 1
fi
if ! grep -aq 'res-ok' "$RUNTIME_LOG"; then
   echo "run_m1: Files res/Close/Rename demo output not seen" >&2
   tail -30 "$RUNTIME_LOG" >&2
   exit 1
fi
if ! grep -aq 'in-eof' "$RUNTIME_LOG"; then
   echo "run_m1: In module demo output not seen" >&2
   tail -30 "$RUNTIME_LOG" >&2
   exit 1
fi
if ! grep -aq '2.50000E+00' "$RUNTIME_LOG" || ! grep -aq 'term-ok' "$RUNTIME_LOG"; then
   echo "run_m1: Reals/Term demo output not seen" >&2
   tail -30 "$RUNTIME_LOG" >&2
   exit 1
fi
if ! grep -aq '8.000000' "$RUNTIME_LOG" || ! grep -aq '3.141593' "$RUNTIME_LOG"; then
   echo "run_m1: LONGREAL/MathL demo output not seen" >&2
   tail -30 "$RUNTIME_LOG" >&2
   exit 1
fi
if ! grep -aq '8000' "$RUNTIME_LOG" || ! grep -aq '8001' "$RUNTIME_LOG" \
   || ! grep -aq '8002' "$RUNTIME_LOG" || ! grep -aq '8003' "$RUNTIME_LOG"; then
   echo "run_m1: Input module demo output not seen" >&2
   tail -30 "$RUNTIME_LOG" >&2
   exit 1
fi
if ! grep -aq '8100' "$RUNTIME_LOG" || ! grep -aq '8103' "$RUNTIME_LOG" \
   || ! grep -aq '8105' "$RUNTIME_LOG"; then
   echo "run_m1: XYplane module demo output not seen" >&2
   tail -30 "$RUNTIME_LOG" >&2
   exit 1
fi
if ! grep -aq '8210' "$RUNTIME_LOG" \
   || ! grep -aqE '^(8211|8212)$' "$RUNTIME_LOG" \
   || ! grep -aq 'err-ok' "$RUNTIME_LOG"; then
   echo "run_m1: Args/Err demo output not seen" >&2
   tail -30 "$RUNTIME_LOG" >&2
   exit 1
fi
if ! grep -aq 'hello-env' "$RUNTIME_LOG" || ! grep -aq '8300' "$RUNTIME_LOG"; then
   echo "run_m1: Env demo output not seen" >&2
   tail -30 "$RUNTIME_LOG" >&2
   exit 1
fi
if ! grep -aq '8310' "$RUNTIME_LOG" || ! grep -aq '8315' "$RUNTIME_LOG" \
   || ! grep -aq '8320' "$RUNTIME_LOG" || ! grep -aq -- '-123' "$RUNTIME_LOG"; then
   echo "run_m1: Convert demo output not seen" >&2
   tail -30 "$RUNTIME_LOG" >&2
   exit 1
fi

#  M53: the VM ran an image inside the guest.  The fixture's output line is
#  unique on purpose, so it cannot be confused with the Ada backend's own
#  markers - seeing it proves the Aegir build of the VM loaded, verified and
#  executed a .obc image under Aegir.  (The image is emitted by the host
#  front end for now; wiring the in-guest compiler to write its own .obc is
#  the next step, at which point the fixture disappears.)
if ! grep -aq 'vm elf ok 55' "$RUNTIME_LOG"; then
   echo "run_m1: the staged VM did not run its image in-guest" >&2
   tail -30 "$RUNTIME_LOG" >&2
   exit 1
fi

echo "run_m1: PASS"
