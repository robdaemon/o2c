# RESUME — starting point for the next session

Written at the end of a long session on the bytecode backend's FFI surface,
then corrected and extended by the two sessions that followed it - the unary
operators, then construct coverage.
Read this first; the details live in `docs/bytecode-gaps.md`.

    HEAD            aad25dc (tests: construct coverage, from the lexer)
    commits         297
    fixtures        68 in tests/bc/
    foreign natives 21 in vm/obc_vm.adb
    state           all suites green, zero warnings, tree clean

## 1. Where things stand

**All six suites pass** — run them before touching anything, to confirm the
starting point is what this file claims:

    export AEGIR_ROOT=/home/rroland/src/aegir
    export XDG_CONFIG_HOME=$HOME/.config XDG_DATA_HOME=$HOME/.local/share
    export XDG_RUNTIME_DIR=/tmp/alrrt TMPDIR=/tmp
    timeout 900  tests/run_bc.sh
    timeout 600  tests/run_vm.sh
    timeout 3000 tests/run_stress.sh
    timeout 1800 tests/run_m1.sh          # the guest build; catches Aegir-side breaks
    timeout 300  tests/bytecode_gaps.sh   # the executable half of the checklist
    timeout 300  tests/coverage.sh        # every lexer token kind is exercised

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

### ...and the session after that one: the unary operators

- **`not`/`~` and unary `-` emitted no opcode.** They compiled, ran, and stored
  the operand unchanged — `x := -y` printed the value of `y`, `if not f` took
  the true branch for a true `f`. Silent wrong images, and invisible to section
  A because they never *refuse*. Both now emit (`Neg`/`Rneg` for a sign,
  `b = 0` for `not`), `tests/bc/unops.ob2` locks them by value, and
  `bytecode_gaps.sh` asserts them — see §3a.
- **The `SET or` entry this file used to carry was wrong**, and the way it was
  wrong is the useful part: see §3a and `docs/bytecode-gaps.md` section C.

## 3. Next tasks, in order

### 3a. DONE — but not the task this section named. Read the correction.

**The entry this section used to carry was WRONG, and the wrongness is the
finding.** It said `or` on a SET is "accepted by the Ada backend and rejected by
the bytecode backend". It is accepted by NEITHER. The operand-type check at
`o2c_compiler.adb:4443` runs **before** the `Bytecode_Mode` test, so SET operands
raise the same `O2c_Error` in either mode — a front-end limit, not a backend
divergence, and therefore something a differential could never have found: both
backends agree.

Measured, not inferred — by calling the Ada-text entry point
`O2c_Compiler.Compile` (the M1 door, which never sets `Bytecode_Requested`):

    c := a or b;          Ada mode: O2c_Error   bytecode: O2c_Error
    c := a + b;           Ada mode: compiles    bytecode: compiles, runs
    f := (1=1) or (2=3);  Ada mode: compiles    bytecode: refuses, loudly

The site's two mode branches had been crossed: `" or "` is emitted on the
BOOLEAN branch, which bytecode refuses two lines earlier, while the SET branch
is the one that raises.

**What that construct was actually hiding.** `not` / `~` and unary `-` emitted
**no opcode at all** — neither implemented nor refused. They compiled, ran, and
stored the operand unchanged:

    x := -y     printed  7   for y = 7      (not -7)
    g := not f  printed  1   for f = true   (not 0)

Silent wrong images — the exact failure the "default is refusal" work exists to
eliminate — and invisible to the checklist, which is generated from the
compiler's *refusals* and so cannot see a construct that never refuses.

**Both fixed.** `Neg`/`Rneg` are now emitted for a unary sign (`LONGINT` still
refuses, consistently with its other arithmetic), and `not b` is emitted as
`b = 0`, which needs no new opcode because a BOOLEAN is 0/1 in this VM.
`tests/bc/unops.ob2` locks both by value and `bytecode_gaps.sh` asserts them.
The change is depth-neutral by construction, so the `FOR` header's `BY`
discard — and every other stack site — is unaffected.

**What is left at this site** is the loud half, now recorded in
`bytecode_gaps.sh` as `blocked`: `&` and `or` on BOOLEAN values. Both need
AND/OR opcodes, and the spec has none — `docs/obc-image.md` puts BOOLEAN at
0x66/0x67/0x68 (BEQ/BNE/BTEST) with 0x72–0x7F reserved.

### 3b. DONE — `tests/coverage.sh`, and it is not a grep

The language's surface is the lexer's token kinds
(`compiler/o2c_lexer.ads`, `Tok_*`). A construct with no fixture cannot be
checked by a differential, because a construct no test uses cannot disagree.

The check is now standing, and it differs from what this section originally
prescribed in the two places that mattered. The original was: *grep the corpus
for each `Tok_*` spelling and require a hit.* It reported "exactly two token
kinds with no fixture anywhere — `>=` and `or`", and **both halves of that were
wrong: the real number is seven, and a hit says nothing about whether the
construct works.**

- **The corpus must be `tests/bc` only.** The grep also walked `samples` and
  `tests/vm`. `~`, `loop`, `exit` and `by` all appear in `samples/hello.ob2`,
  which no test and no Makefile target compiles, and `tests/vm/*.asm` is
  assembly whose comments are full of keyword-shaped words. So four constructs
  read as "covered" while three of them were silently wrong in bytecode.
- **The tokens must come from the lexer, not a pattern.** `tools/o2c_tokscan`
  lexes the corpus and reports the kinds that occur, so a token inside a comment
  cannot count and `>=` cannot be confused with `>` followed by `=`.
- **Every unexercised kind must be exempt or a RECORDED known gap** with a probe
  pinning its current behaviour, so the list cannot decay: a gap that is
  silently fixed fails the check.

What the seven were, and what became of them:

    TOK_GE  `>=`      works - no fixture.  Now tests/bc/relops.ob2 (value-locked,
                      and written so `>=`/`>` differ on a = b, which a single
                      mis-emitted opcode could not survive).
    TOK_BY  `by`      works - no fixture.  Now tests/bc/forstep.ob2.  Worth a
                      fixture because the step is used from its TEXT, not the
                      stack, so a stray slot is invisible in a golden.
    TOK_LOOP/TOK_EXIT  SILENTLY WRONG - the body ran once, EXIT did nothing, so
                      an infinite loop terminated.  FIXED (3e).
    TOK_AMP `&`       refuses loudly.  Known gap, pinned in coverage.sh.
    TOK_OR  `or`      refuses loudly.  Known gap, pinned in coverage.sh.
    TOK_AND `AND`     reserved by the lexer and never parsed - a grammar hole,
                      not a missing operator.  Known gap, pinned.
    TOK_ERROR         not a construct - exempt.

Descending FOR is the one known gap coverage CANNOT see, and that is the point
of the caveat at the end of this section: its tokens (`FOR`, `TO`, `BY`,
`MINUS`) are all exercised by ascending loops, so the token check passes while
the construct is wrong. It is pinned by a probe in `coverage.sh` instead. `for i
:= 3 to 1` never runs its body, because `Asc` comes from whether the `BY` text
starts with `-`, and the way to ask for a descent — `by -1` — is rejected with
"FOR BY must be an integer constant": `-1` reaches the header as the text
`-(1)`. The header's digit check even allows a leading `-`, so `by -1` was
*meant* to work. **A value fixture cannot hold this**: asserting that `3 to 1`
sums to 0 would be asserting wrongness as if it were correct, which is why it
lives as a known-gap probe and not in tests/bc.

**The lesson: coverage says where to look, not what is there.** It found the
constructs no test reached; it could not tell that three of them were wrong, and
the one construct that is wrong while fully covered is invisible to it by
construction. That is 3c's job.

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

### 3e. DONE — `LOOP` / `EXIT`

The third member of the silent wrong-image class, and the worst: found by 3b's
coverage check, not by a fixture. `Parse_Loop` and `Parse_Exit` appended only
Ada text, so in bytecode mode `LOOP` emitted no back-jump and `EXIT` emitted
nothing. **An infinite loop terminated**: `loop i := i + 1 end` printed 1.

Fixed by giving bytecode what the Ada text gets for free: a top label and a
back-jump in `Parse_Loop`, and an exit label — recorded per depth in
`Bc_Loop_Exit` alongside the text-label array `Loop_Lbl`, both bounded by the
same checked limit — that `Parse_Exit` jumps to. Leaving a nested `WHILE`/`FOR`
needs no unwinding: frames are frame slots and every loop is jumps.

`tests/bc/loopexit.ob2` is written for that last point. Its fourth case is an
`EXIT` from inside a nested `WHILE`, and if the exit target were the `WHILE`'s
the program would not print a wrong number — **it would never terminate**,
which is why the fixtures run under a timeout. Coverage cannot see a wrong exit
target; only executing it can.

For the next silent-image hunt: coverage found this only because `loop`/`exit`
had NO fixture. A construct that is exercised AND wrong is invisible to
coverage — that is exactly the descending-FOR entry in 3b, and it is 3c's job.

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
  `tools/bin/o2c_tokscan` links the lexer and is the coverage check's oracle -
  it is built by the same `make tools-host`, and a stale one would report
  coverage for a lexer that no longer exists.
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
    tests/coverage.sh          every lexer token kind is exercised, or a recorded gap
    tests/run_bc.sh            fixtures in tests/bc/ (.ob2 + .out golden)
    tests/run_m1.sh            the guest build and the Ada-vs-VM diff
    compiler/o2c_compiler.adb  ~11k lines; the FFI call sites are near the end
    compiler/o2c_lexer.ads     the token kinds coverage is measured against
    vm/obc_vm.adb              the VM; natives are in the native dispatch
    vm/vm_platform.ads         the seam spec
    vm/compat-host|aegir/      the two seam bodies
    tools/o2c_bc_host.adb      the host front end; takes libs as extra args
    tools/o2c_tokscan.adb      lexes a corpus and reports the kinds it finds

## 7. One thing to decide early — DECIDED

The differential (3c) is the standing answer to "stop surprising me", but it
only covers what the corpus exercises. **Ask whether the fixtures should be
written per *construct* (3b) or per *feature*.** Per-construct is what makes
coverage checkable mechanically against the lexer; per-feature is what the
previous 64 fixtures are. The answer probably changes how 3b is done, so decide
it before writing fixtures.

**Decided: per CONSTRUCT, mechanised against the lexer's `Tok_*` list.** The
`or`/`not` work settled it. Both were invisible precisely because no fixture
exercised the *token*: the corpus had 64 fixtures covering plenty of features
and still never evaluated a unary operator. A feature-level list cannot be
checked mechanically, and an uncheckable list is what let a silent wrong image
survive. Two caveats to carry into the work, both measured above: the
mechanical grep needs a per-token fixture **in `tests/bc`** (a hit in `samples`
does not count — nothing runs it), and a hit only says *look here*, so each new
fixture must assert the construct's **value**, not merely that it compiles.
