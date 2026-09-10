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
