# The o2c bytecode VM — plan

Status: **proposal** (nothing implemented yet).  Written after the M50–M52
extension modules landed, when the heap/GC question came up: the Ada backend
allocates from the RTS arena and never frees, because Oberon's collector has
no equivalent in Ada.  The answer chosen is to add a **bytecode backend plus a
VM** and to adopt **libgc (Boehm-Demers-Weiser)** as the VM's memory manager.

## Why a VM, and why it makes GC tractable

- **Roots become enumerable.** In the Ada backend, a live Oberon pointer can
  sit in any Ada stack slot or register, so a collector could only be
  conservative.  In the VM, every stack slot has a statically known type at
  every instruction (the emitter knows the expression types it has already
  computed), so the VM stack and the module globals are *precise* root sets:
  GC maps are derived from the bytecode, not guessed from a stack image.
- **One allocation path.** All Oberon heap objects come from the VM's own
  allocator, so switching that allocator to `GC_malloc`/`GC_malloc_atomic`
  covers the whole language in one place (the arena stays for VM metadata).
- **A portable target.** `.obc` images are host-independent; the same image
  runs on the VM under Aegir and on a host build of the VM during
  development (host iteration without QEMU, using the same `o2c-stub`-style
  RTS shims the compiler harness already uses).
- **The Ada backend is the oracle — but a temporary one, and its retirement
  is planned, not incidental.** The VM must reproduce its stdout byte for
  byte while both exist.  Because the Ada backend needs a host Ada/GCC
  toolchain it cannot be the endgame (porting GCC into the guest is
  prohibitive), so validation must outlive it: **golden expected outputs
  checked into `tests/` plus the host-built VM as the reference tool**
  (decided).  The dual-backend diff stays as a temporary extra gate until the
  Ada emitter is deleted.

Non-goals of this plan: replacing the Ada backend, JIT compilation, threads
inside the VM, and garbage collection for the *Ada* backend (that stays
arena-only, documented as today).

## Architecture

```
 Oberon-2 source
        |
   front end (existing single-pass parser/semantic analysis in
   compiler/o2c_compiler.adb)
        |
   emit layer  ---- currently: Ada text via Append_Body/O2c_Put_*
        |
        +--> Ada backend (unchanged, the oracle)
        +--> bytecode emitter (new) --> .obc image on the Aegir fs
                                          |
                                     vm/ (new): loader + interpreter
                                     running as an Aegir program
                                          |
                                     libgc (new): GC_malloc/GC_malloc_atomic
```

The compiler already funnels every statement and expression through one emit
layer (`Append_Body`, `O2c_Put_Int`/`O2c_Put_Real`/`O2c_Put_LReal`,
`Compile_Module`), so the bytecode emitter can be added *beside* the Ada
emitter rather than by rewriting the front end: introduce a small IR
(three-address records + a label/layout pass) that the front end fills in,
then render that IR as Ada **or** as bytecode.  The Ada backend is switched
over to the IR first (a pure refactor, verified by the existing regression),
so the VM lands against a stable, already-tested interface.

## Decisions to freeze before coding

1. **Instruction style — DECIDED: stack bytecode as the wire format**
   (operand stack, `LOAD_L k`, `IADD`, `CALL n`), with a **three-address IR**
   underneath so a future native/optimizing tier has its substrate.  Rationale
   (recorded after comparing the alternatives): the front end is an
   expression-tree walker, which *is* a stack machine, so codegen is nearly
   free, whereas a register form needs liveness analysis, allocation and
   spilling before its ~1.5–2.5× instruction-count win is realizable at all.
   The choice is sticky (opcode style is a major-version commitment), so the
   escape range is reserved for fused/short forms and an internal register
   representation.  The JVM is the precedent: stack machine, typed opcodes,
   operand-stack verification, `StackMapTable` ≈ our `STACKMAP`.
   Consequence of the VM being the *shipping* executor (the Ada backend is
   scheduled for removal — the guest cannot host an Ada/GCC toolchain, and
   `o2c.elf` already runs in the guest): throughput is clawed back with
   interpreter work (superinstructions, quickening), not a JIT — an in-guest
   translator would need an assembler, which is the lift this design avoids.
   The kernel has no W^X policy, so nothing *blocks* a later native tier.
2. **Typed opcodes**: `IADD`/`RADD`/`LADD` rather than one polymorphic `ADD`.
   Costs opcode space (cheap, see rule 7), buys static operand types (GC) and
   no runtime type dispatch.
3. **Object header**: one word = descriptor pointer; descriptors are emitted
   into the image (they carry element type, array length *not* baked in,
   record layout, and the method table).  Pointers/references are
   `NIL`-able indices/addresses into the VM heap.
4. **Image format**: magic + version + wordsize, import/export tables, type
   descriptors, code, module-init entry point.  Loader rejects a version it
   does not know.  Images are emitted deterministically (reproducible).
5. **Calling convention**: one frame = local slots + operand stack; dynamic
   dispatch via the descriptor's method table; `WITH`/guards use the
   descriptor chain.  Builtin modules (Out, Files, …) are *native* calls, not
   bytecode.
6. **Opcodes are append-only**, exactly like syscall/ABI numbers (project
   rule): reserve ranges now (`0x00–0x3F` load/store, `0x40–0x7F` integer,
   `0x80–0xBF` float/char/set, `0xC0–0xFF` control/oop/call) and never
   renumber.

## Milestones

Each milestone is committed separately and is only "done" when the Ada
backend's regression still passes **and** the new VM path is exercised.

- **M53 — VM core.** IR + `o2c` bytecode emitter for INTEGER/CHAR/BOOLEAN/SET/
  REAL/LONGREAL arithmetic, comparisons, `IF`/`WHILE`/`REPEAT`/`FOR`/`CASE`,
  procedures and the module body; `vm/` crate with loader + interpreter;
  build targets for **host** and for **Aegir**.  Acceptance: the demo's
  arithmetic/control-flow prefix runs under the VM and matches the Ada
  backend's output; `run_m1` grows a VM pass.

  **Progress — thin slice done (end-to-end, host build).**  Deliberately
  built from the runtime end first, so the container and opcodes are proven
  by execution before the emitter depends on them:
  - `vm/obc_vm.ads|adb` — loader, verifier and stack interpreter for the
    subset a module body needs (arithmetic, comparisons, globals,
    `JMP`/`JZ`/`JNZ`, `Out.Int`/`Out.String`/`Out.Ln` as natives).  Every
    other v1 opcode is *defined but reported as not implemented*, so a
    program using one fails loudly.  `Run` is total: a malformed image is
    rejected with a status, never a CONSTRAINT_ERROR.
  - `vm/vm.gpr` + `make vm-host` — host build, deliberately **not** through
    the aegir crate's alr environment (that selects the riscv64 toolchain):
    the host VM is the reference tool the golden tests diff against and has
    to stay runnable after the Ada backend is retired.  Zero warnings.
  - `tools/obc_asm.py` — a test-only assembler for hand-built images (it
    also builds the loader's negative cases).
  - `tests/vm/slice.asm` + `tests/vm/slice.out` — golden output, and
    `tests/run_vm.sh` — the positive diff plus six rejection cases (bad
    magic, future minor version, size mismatch, jump out of range,
    not-implemented opcode, native arity mismatch).  All pass.
  **Progress — the emitter's encoder, verified.**  `compiler/o2c_bc.ads|adb`
  holds the bytecode emission state: opcodes, code buffer with label fixups,
  constant pool (integer words plus a string area), an interned globals
  table, and a *computed* operand-stack high-water mark (so `stack_max` is
  derived, not guessed).  `Encode` writes the v1 container.
  `vm/bc_emit.adb` drives that API to build the same program
  `tests/vm/slice.asm` hand-assembles, and `run_vm.sh` now checks its image
  runs to the same golden output - so the encoder (offsets, pool layout,
  jump resolution) is verified against the interpreter before any front-end
  hook depends on it.  Three bugs it caught, all worth remembering:
  - `2 ** 56` does not fit a 32-bit `Natural`, so the 64-bit header/table
    writers use `Unsigned_64` shifts;
  - interning a global before `Begin_Mode` is wiped by its reset - `Global`
    now raises if called outside bytecode mode rather than silently losing
    the slot;
  - a negative INTEGER pool word must be built by hand in two's complement
    (`U64'Last - (-(V + 1))`), because converting a negative value to
    `Unsigned_64` zero-extends and the VM would read it back positive.

  **Progress — the front-end hooks, end to end.**  `o2c` now emits bytecode
  from real Oberon-2 source.  The hooks are gated on
  `O2c_BC.Bytecode_Mode`, which only `Compile_Multi` sets - around the
  *main* module's body, never the builtin modules - so the Ada backend's
  output is untouched when bytecode mode is off.  Wired so far:
  integer/string/`TRUE`/`FALSE` factors, the scalar-variable factor, the
  operator tails in `Parse_Term`/`Parse_Simple`/`Parse_Expr` (INTEGER and
  CHAR only), `Parse_If`/`Parse_While` (via a monotonic label counter),
  scalar assignment, and `Out.Int`/`Out.String`/`Out.Ln`.  Constructs
  outside the slice raise `Wrong_Construct` with a specific message rather
  than emitting a wrong image; a module body that declares procedures is
  refused wholesale.

  `tools/o2c_bc_host` compiles one module to an image with **no Aegir
  runtime and no QEMU** (the compiler core withs only Ada and the lexer),
  so the emitter is testable in seconds; `tests/run_bc.sh` compiles
  `tests/bc/sum.ob2` (globals, `WHILE`, arithmetic, `Out.*`) and
  `tests/bc/ifelsif.ob2` (`IF`/`ELSIF`/`ELSE`) to images, runs them on the
  host VM and diffs the golden output, then checks that
  `tests/bc/unsupported.ob2` (a REAL literal) fails the compile with a
  clear diagnostic.  All pass, and `run_m1` still passes, so the Ada path
  is unaffected.

  Two bugs the golden test caught: a string literal's token text is
  *unquoted* (the Ada text is quoted separately), so trimming the ends ate
  one byte at each end; and the 64-bit header/table writers needed
  `Unsigned_64` shifts.

  **Progress — the VM builds for Aegir.**  `make vm-aegir` produces
  `vm/bin-aegir/vm.elf` (riscv64, statically linked, warning-free) with the
  same driver, interpreter *and* image input as the host build; only the
  program lifecycle is platform-specific:

      vm/vm_io.adb                    Ada.Sequential_IO  (both platforms)
      vm/compat-host/vm_platform.adb  exit status
      vm/compat-aegir/vm_platform.adb CLI.Init / CLI.Exit_With

  **Correction to an earlier note in this document.**  An earlier revision
  claimed the runtime has no `Sequential_IO`/`Direct_IO`/`Ada.Streams`, so
  image input was split per platform through `Aegir_User.Files`.  That was
  wrong, and the split has been removed.  The runtime is a near-complete
  libgnat: `ada_source_path = gnarl_user gnat_user gnat_full gnat`,
  `ada_object_path = adalib`, **608 source units with 607 built**, and the
  units are all there - `a-sequio`, `a-direio`, `Ada.Streams.Stream_IO`
  (which GCC 15 names `a-ststio`, which is why the first search missed it),
  the narrow `Ada.Text_IO` family with its children, `Ada.Directories`,
  `Ada.Environment_Variables`, calendars, containers, sockets - plus the
  vendored C support in `gnat_full/` (`adaint.c`, `argv.c`, `cstreams.c`,
  `env.c`, `i-cstrea`, `s-fileio`, `sysdep.c`, `targext.c`).  The mistake
  was searching only `gnat/` (the pool directory) and not `gnat_full/` and
  `adalib/`.  Proof beyond file listings: `userspace/copy` recompiles and
  links against `Ada.Streams.Stream_IO`, and `vm.elf` itself now links
  `Ada.Sequential_IO`.

  What the port *did* require, verified rather than assumed:
  `Ada.Command_Line` and console `Ada.Text_IO` work in the guest
  (`userspace/echo` documents the chain: Text_IO -> newlib stdio -> gloss
  fd 1 -> console, composing with redirection), so the driver and the
  `Out.*` natives needed no changes.  Object and exec directories are
  separate (`obj-aegir`, `bin-aegir`) so the riscv64 build never collides
  with the host one.

  The one genuine gap in the runtime, for the record: **no wide-character
  units** (no `Wide_Character`/`Wide_String`, no `Wide_Text_IO` or
  `Wide_Wide_*`); `gnat_full/` vendors only the narrow `Text_IO` family.
  Nothing references them today.

  **Progress — the VM runs an image in the guest.**  The aegir initrd stages
  `vm.elf` as `Tests/Vm` (program 42, `console fs`) with a fixture image at
  `Tests/O2cBC/VmGreet.obc`, produced by the host front end
  (`make vm-aegir vm-fixture`), and `run_m1` asserts the VM's output line -
  chosen to be unique so it cannot be confused with the Ada backend's own
  markers.  Two additions made the guest run possible: `VM_Platform.
  Resolve_Path` (guest paths are resolved against the current directory,
  as `cd`/`copy` do with their arguments) and a default image path (a
  program spawned from `System/Manifest` receives no arguments).

  **The trap this cost, worth remembering:** the first staged boot died with
  `scause 0xf` (store page fault), `stval 0x7fefff20`, and *no output at
  all*.  `Run` declared its image slab as a local 1 MiB array, and a guest
  user stack is **64 pages = 256 KiB** (`kernel-processes.ads`:
  `User_Stack_Top = 16#8000_0000#`, `User_Stack_Pages = 64`), so the array
  overflowed the whole stack on the first store into `Run`'s frame - before
  the program could print anything.  The slab and the payload copies are now
  heap objects, and `Decode` makes the two 0-based payload copies once
  (`Verify`/`Execute` alias them with `renames`).  **Rule for guest code:
  nothing large on the stack.**

  **Progress — the guest compiles *and* runs bytecode, in one process.**
  o2c embeds the VM (`crate/o2c.gpr` pulls in `../vm` plus its Aegir
  platform bodies, excluding the VM's other mains), so after compiling
  `Tests/O2cLib/VmGreet.ob2` in bytecode mode it executes the image through
  `OBC_VM.Run_Image` - the same decode/verify/execute path as the
  file-driven `Run`, which now shares a `Run_Buffer` core.  A min-mode boot
  therefore shows:

      o2c bytecode: image 352 bytes
      vm elf ok 55
      o2c bytecode: vm ok

  **Why not via a file:** the first design had o2c write the image and the
  standalone VM read it back, and it hit three walls in a row - `Tests/`
  does not exist on the writable volume (that is the initrd's tree),
  then `No space left on device` for a 352-byte file at `BD0:` root, and
  underneath both, a race: **manifest programs are spawned concurrently**
  (`userspace/init/init.adb` spawns and never waits), so the VM could start
  before the compiler had written anything.  Executing the image in-process
  removes the file, the volume and the race together - and it makes the
  compiler self-checking, which is what we want from it anyway.  Keep the
  volume question for the standalone VM (a real use case: running programs
  from files), not for the milestone.

  **What the test learned the hard way:** `run_m1` asserted on o2c's output
  as soon as the *demo* printed its last marker, but the demo (program 41)
  and o2c (program 40) are concurrent, so the check raced the program it was
  checking.  It now waits for o2c's own line first, asserts single-write
  tokens where possible (a marker split by a concurrent writer would
  otherwise miss), checks the build's exit status instead of ignoring it,
  and preserves the last boot log under `/tmp/run_m1_boot.log` on exit -
  a failing run used to delete the only evidence.

  Remaining for M53: the standalone VM reading images from the writable
  volume (blocked on how full `befs.img` is); then more of the language in
  the slice (REAL, SET, `FOR`,
  `REPEAT`, `CASE`, arrays, pointers, procedures - each with its own
  opcodes already reserved), then an Aegir build of the VM so the in-guest
  pipeline can compile *and run* without a host toolchain, and the
  Ada-vs-VM diff in `run_m1`.
- **M54 — data.** ARRAY (open and fixed), RECORD, POINTER, `NEW`, string
  builtins (`COPY`, `CHR`/`ORD` interactions, comparison), nested procedures.
- **M55 — OOP.** Type extension, type-bound procedures, dynamic dispatch,
  `WITH` guards, type tests; descriptor method tables in the image.
- **M56 — modules.** Imports/exports, multi-module images, initialization
  order, and the interaction with the compiler's `Max_Units`/provided-module
  bookkeeping.
- **M57 — native module bridge.** Out/In/Input/Err/Args/Env/Files/Strings/
  Reals/Math/MathL/Term/XYplane as VM natives, so the *whole* M1 demo runs
  under the VM.  Acceptance: `run_m1` diffs VM output against the Ada
  backend's, byte for byte, for the same source tree.
- **M58 — oracle parity.** Run the compiler's own sample set and the M39–M56
  harness programs under the VM; any divergence is a VM bug until proven
  otherwise.
- **M59 — libgc.** Fetch a sha256-pinned `bdwgc` tarball at build time and
  apply `third_party/patches/bdwgc-aegir-*.patch` (nothing vendored in git,
  per project rule).  The port needs:
  - a `gcconfig.h` clause: `MACH_TYPE`/`OS_TYPE`, `CPP_WORDSZ = CPP_PTRSZ = 64`,
    `ALIGNMENT = 8`, `DATASTART`/`DATAEND` for the image's static data, and
    `STACKBOTTOM` from Aegir's fixed user-stack window (we know it).
  - `GET_MEM`: Aegir has `_sbrk` on its own VA arena already (gloss), so a
    sbrk-backed heap is the cheap path; a dedicated memobj-backed window is
    the follow-up if we want `mmap`-style semantics.
  - **single-threaded build** (no `GC_PTHREADS`): skips `stop_world`, the
    signal machinery and the pthread lock layer entirely.
  - **no `MPROTECT_VDB`** initially — stop-the-world mark-sweep only, so no
    write-protect faults and no `mprotect` dependency; incremental VDB is a
    later optimisation if pause times ever matter.
  - all VM object allocation routed through `GC_malloc` (records, arrays with
    pointer elements) and `GC_malloc_atomic` (char arrays/strings, numeric
    arrays), `GC_init` at VM start, and `GC_add_roots` for the VM stack,
    register window and module globals.
  Acceptance: an allocation loop that today dies with `Storage_Error`
  completes; the M1 demo and M58 parity still hold.
- **M60 — collector hardening.** GC stress/fuzz re-runs (the FS fuzz tests
  must stay idempotent), a pause/allocation measurement to spot
  performance degradations (the suite runs under `timeout` for exactly this),
  and README/doc updates replacing "no automatic collection" with the VM's
  precise story (and keeping the Ada backend's arena caveat).

## Risks

- **The libgc port is the single largest piece** (M59).  It is deliberately
  last: by then the VM exists, all allocation has one path, and roots are
  known — the only unknowns left are `gcconfig.h` values and `GET_MEM`.
- **Conservative vs precise roots.** Start conservative (`GC_add_roots` over
  the VM stack window + globals): simple, correct, but interior pointers
  retain garbage.  Precise frame maps become possible because the emitter
  knows slot types; treat as an optimisation, not a requirement.
- **Performance.** The VM will be slower than compiled Ada; that is
  acceptable because the Ada backend remains the shipping path and the
  oracle.
- **Aegir memory model.** The heap must be memobj-backed and contiguous
  enough for a real collector; the sbrk-backed path is fine to start.
- **Scope creep.** Each milestone must keep the existing regression green;
  if the VM breaks `run_m1`, the VM is wrong, not the regression.
