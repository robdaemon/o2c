# RESUME — starting point for the next session

Written at the end of a long session on the bytecode backend's FFI surface.
Read this first; the details live in `docs/bytecode-gaps.md`.

    HEAD            2e3cc7b
    commits         292
    fixtures        64 in tests/bc/
    foreign natives 21 in vm/obc_vm.adb
    state           all suites green, zero warnings, tree clean

## 1. Where things stand

**All four suites pass** — run them before touching anything, to confirm the
starting point is what this file claims:

    export AEGIR_ROOT=/home/rroland/src/aegir
    export XDG_CONFIG_HOME=$HOME/.config XDG_DATA_HOME=$HOME/.local/share
    export XDG_RUNTIME_DIR=/tmp/alrrt TMPDIR=/tmp
    timeout 900  tests/run_bc.sh
    timeout 600  tests/run_vm.sh
    timeout 3000 tests/run_stress.sh
    timeout 1800 tests/run_m1.sh          # the guest build; catches Aegir-side breaks
    timeout 300  tests/bytecode_gaps.sh   # the executable half of the checklist

`make build` / `make vm-host` / `make tools-host` / `make vm-aegir`, all with
`AEGIR_ROOT=...`, build clean with zero warnings.

### 20 FFI procedures work, each probe-verified

    Convert.ToInt / ToReal / FromInt
    Files.Delete / Rename
    Env.Get / Set
    Args.Get
    XYplane.Open / Clear / Dot / IsDot / Key
    In.Open / String / Name / Char / Int / LongInt / Real

Verified by **effect** where possible (a file deleted, an env var round-tripped,
a plane cell set then read), and by output where not. `tests/bytecode_gaps.sh`
asserts the working set and **fails when a gap is fixed**, so an entry cannot
outlive its gap.

## 2. What changed this session

- **The default is refusal.** An imported-module call with no bytecode emission
  now refuses instead of building Ada text that bytecode discards. Before this,
  `Math.cos (0.0)` compiled, ran, and printed `0.000`; `Strings.Length ("abcd")`
  printed `16`. Refusal is the default and the implemented set is the allowlist
  — the previous shape enumerated what was *missing* and went stale silently,
  which is how those two got through.
- **The expression path exists.** `IsDot`/`Key` were the first primitives to
  *return* a value; every earlier helper wrote through an address. The imported
  *function* call had no bytecode branch at all.
- **`VM_Platform` gained** `Get_Env`/`Set_Env`, `Arg_Get`, `Delete_File`,
  `Rename_File`, `Get_Line`. `vm_main` now forwards arguments after the image as
  the interpreted program's own.
- **`docs/bytecode-gaps.md` is the checklist**, and its section A is generated
  from the compiler's refusals rather than maintained by hand:

      grep -o '"bytecode backend: [^"]*"' compiler/o2c_compiler.adb | sort -u

## 3. Next tasks, in order

### 3a. Fix `SET or` — small, named, loud

`or` on a SET is **accepted by the Ada backend** (its emitted text is `"a or b"`)
and **rejected by the bytecode backend** (`OR needs BOOLEAN operands`). Set
union via `+` works; `or` does not. No fixture used `or` at all, which is why
the differential could never have found it.

This is a real gap in a construct one backend supports and the other does not.
Start here: it is small and it is already diagnosed.

### 3b. Coverage: a fixture per construct

The language's surface is the lexer's token kinds
(`compiler/o2c_lexer.ads`, `Tok_*`). A construct with no fixture cannot be
checked by a differential, because a construct no test uses cannot disagree.

A first pass over `tests/bc`, `samples` and `tests/vm` found exactly two token
kinds with no fixture anywhere — `>=` and `or`. `>=` works; `or` is 3a. Make the
check standing: **grep the corpus for each `Tok_*` spelling and require a hit.**

### 3c. Differential: run the corpus through both backends

`run_m1` already diffs Ada against the VM, but for **one demo program**. Extend
it to the fixtures. Two things to get right:

- The Ada side needs the **guest** toolchain, so this runs in the guest, not as
  a host sweep.
- Some differences are legitimate — the Ada backend has its own known gaps, and
  PASS-count variance between runs is already cosmetic. The diff must
  distinguish "VM wrong" from "both differ from the golden".

Coverage finds what no test reaches; the differential finds what a test reaches
but the VM gets wrong. **Neither alone is enough** — that is the whole finding,
and it is argued at length in `docs/bytecode-gaps.md`.

### 3d. `Files.Old` / `Read` / `Write` / `Close` / `New`

Deferred, and now **sized** rather than open. Reading the bodies settled it:

- The types are ordinary (`File` = pointer to a record; `Rider` = a record).
- **Every statement in the module is already supported** by the bytecode
  backend — record and pointer assignment, field access, comparison, array
  indexing, `new`. The only non-bytecode parts are the FFI primitives.
- So the module needs **compiling, not reimplementing**: its primitive calls
  become native calls, exactly as `Convert.ToInt`'s call site does.
- **The obstacle is ordering, not capability.** `Compile_Multi` calls
  `O2c_BC.Begin_Mode` *after* the builtin and library compiles, so builtins are
  always parsed in Ada mode. Moving it earlier would put **every** builtin into
  bytecode mode, and Math/Reals do REAL arithmetic the backend still refuses in
  places. **Scope it to the modules that can actually compile** — Files, Env,
  Args, XYplane, In — leaving Strings, Texts, Math, MathL, Input, Term on the
  Ada path, no worse off than today.

## 4. Method — what worked, and what did not

**Measure; do not infer.** Every wrong turn this session came from an inference
where a measurement was available, and every correction came from reading or
running. Nine probes were wrong before the code was.

**When a probe reports an error, suspect the probe first.** The failures fell
into three flavours, all the same mistake in different clothes:

    searched for a DECLARATION, not a use        (twice)
    assumed a call has PARENTHESES               (once)
    wrong name / wrong syntax / hidden output    (six times)

**Read how a thing is USED, not how it is declared or named.** This fixed
`Convert`'s names, `FDel`'s existence and `Delete`'s meaning. It also settled
whether `In` needed a platform seam (it does — `O2c_In_Load` calls
`Aegir_User.CLI.Get_Line`) and whether `XYplane` did (it does not — the Ada
backend keeps a shadow plane in the program).

**Put the diagnostic where the failure is and let the program report.** Three
rounds of reasoning about `Args.Get` were worth less than one line inside the
compiler, which printed `get=TRUE n3=TRUE` and moved the search to the emission
body.

**When a value looks like evidence, check that the code which would produce it
ran.** `r` reading `-1` looked like a working out-of-range path; the native was
never running and `-1` was uninitialised memory.

**Verify the artefact, not the report.** A scripted edit printed its success
message while changing nothing; `git status` was clean. After any scripted edit,
`grep` for a marker and check `git diff` **before** building.

**Let the compiler catch syntax.** A reserved word (`At`) and a dangling
`elsif` were each one build cycle, not worth reasoning about in advance.

## 5. Traps specific to this repo

- **`tools/bin/o2c_bc_host` links the compiler sources.** After changing any
  `compiler/*.adb` you MUST `rm -f tools/bin/o2c_bc_host && make tools-host`,
  or you will debug a stale binary. `make build` alone is not enough.
- **The `VM_Platform` seam is three files per platform**, not two: the spec, the
  body, and the probe in `vm/compat-aegir/aegir_interface.adb`. Missing the
  Aegir *body* passes all three host suites and only `run_m1` notices.
- **`make -j` is forbidden** — concurrent gprlib corrupts `libaegir_user.a`.
- **Always `timeout`** around tests and the VM; a wedge otherwise spins forever.
- **Kill QEMU with `pkill -f "qemu-system-riscv6[4]"`** — the bracket class
  stops the pattern matching the invoking shell's own command line.
- **`/tmp` is not persistent between sessions** — recreate probe sources.
- **Run the suites from the repo root**; some paths are relative.
- **Ada reserved words that have bitten:** `at`, `yield`, `Entry`, `Body`.
  Identifiers may not end with `_`.
- **Append-only:** opcodes, syscall numbers, ABI handles, foreign native ids.
  New natives go at the end of the foreign table; `labs` is id 5.
- **A test that reports nothing is not a passing test.** A probe that fails to
  create its fixture can pass vacuously — write the fixture immediately before
  the check, as `tests/bytecode_gaps.sh` does for the file operations.

## 6. Files worth knowing

    docs/bytecode-gaps.md      the checklist; section A is generated
    tests/bytecode_gaps.sh     the executable half — asserts the working set
    tests/run_bc.sh            fixtures in tests/bc/ (.ob2 + .out golden)
    tests/run_m1.sh            the guest build and the Ada-vs-VM diff
    compiler/o2c_compiler.adb  ~11k lines; the FFI call sites are near the end
    vm/obc_vm.adb              the VM; natives are in the native dispatch
    vm/vm_platform.ads         the seam spec
    vm/compat-host|aegir/      the two seam bodies
    tools/o2c_bc_host.adb      the host front end; takes libs as extra args

## 7. One thing to decide early

The differential (3c) is the standing answer to "stop surprising me", but it
only covers what the corpus exercises. **Ask whether the fixtures should be
written per *construct* (3b) or per *feature*.** Per-construct is what makes
coverage checkable mechanically against the lexer; per-feature is what the
current 64 fixtures are. The answer probably changes how 3b is done, so decide
it before writing fixtures.
