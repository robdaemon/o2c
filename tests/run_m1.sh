#!/bin/sh
# o2c M1 regression: the full dogfood pipeline.
#
#   1. build o2c.elf (o2c runs under Aegir)
#   2. boot a test-mode initrd staging Tests/O2c; capture the generated
#      Ada (O2C| lines between the markers) and rebuild it on the host
#   3. boot again staging Tests/Hello; assert "hello from Oberon-2"
#
# Requires AEGIR_ROOT (the aegir checkout; no default).
set -eu

: "${AEGIR_ROOT:?AEGIR_ROOT must point at the aegir checkout}"
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK="${TMPDIR:-/tmp}/o2c-m1"
QEMU_LOG="$WORK/boot.log"
RUN_MIN=${RUN_MIN:-300}

rm -rf "$WORK"; mkdir -p "$WORK"

cleanup() {
   pkill -f 'qemu-system-riscv6[4]' 2>/dev/null || true
}
trap cleanup EXIT INT TERM

boot_once() {  # $1 = extra make vars, $2 = marker
   rm -f "$QEMU_LOG"
   ( cd "$AEGIR_ROOT" && make run INITRD_MODE=test \
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
make -C "$ROOT" build AEGIR_ROOT="$AEGIR_ROOT" >/dev/null

echo "run_m1: boot 1/2 - o2c emits Ada for hello"
boot_once "" '--- ada end ---'
awk '/--- ada begin ---/{f=1;next} /--- ada end ---/{f=0}
     f && /^O2C\|/{print substr($0,5)}' "$QEMU_LOG" > "$WORK/hello.adb"
grep -q 'procedure Hello' "$WORK/hello.adb" \
   || { echo "run_m1: no 'procedure Hello' in emitted source" >&2; exit 1; }

echo "run_m1: building the emitted hello on the host"
cp "$ROOT/tests/hello.gpr" "$WORK/"
( cd "$AEGIR_ROOT/userspace/echo" && alr exec -- gprbuild -q -p \
    -P "$WORK/hello.gpr" -aP "$AEGIR_ROOT/userspace/rts" \
    -XAEGIR_ROOT="$AEGIR_ROOT" >/dev/null ) \
   || { echo "run_m1: host build of emitted Ada failed" >&2; exit 1; }

echo "run_m1: boot 2/2 - assert hello output under Aegir"
boot_once "O2C_HELLO_ELF=$WORK/bin/hello.elf" 'hello from Oberon-2'

echo "run_m1: PASS"
