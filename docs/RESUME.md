# RESUME — starting point for the next session

Written at the end of a long session on the bytecode backend's FFI surface,
then corrected and extended by the three sessions that followed it - the unary
operators, construct coverage, and descending FOR.
Read this first; the details live in `docs/bytecode-gaps.md`.

    HEAD            find it with:  git log --oneline -1
    commits         341
    fixtures        81 in tests/bc/
    foreign natives 25 in vm/obc_vm.adb
    state           all suites green, zero warnings, tree clean

The header names no commit hash on purpose: `HEAD` and `commits` describe the
same commit, this file cannot name its own, and a stale hash is worse than a
command. Verify with `git rev-list --count HEAD` and `ls tests/bc/*.ob2 | wc -l`.

## 1. Where things stand

**All seven suites pass** — run them before touching anything, to confirm the
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
    timeout 900  tests/differential.sh    # both backends, three-way vs the golden

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

Descending FOR was the one gap coverage could NOT see, and it is worth keeping
as the demonstration of *why* the caveat at the end of this section matters:
its tokens (`FOR`, `TO`, `BY`, `MINUS`) are all exercised by ascending loops,
so the token check passed while the construct was broken. **It is fixed now**
(3f) and held by `tests/bc/fordown.ob2` like any other construct — but the
lesson it taught stands, and it has no live example any more:

    a construct that is fully covered AND wrong is invisible to coverage.

`for i := 3 to 1` summing to 0 was never the bug — that is correct Oberon-2,
since a descent needs an explicit negative step, and it is what the first
reading mistook for the gap. The bug was that `by -1` could not be written at
all, so no descent was expressible, and only a *descent* can assert that.

**The lesson: coverage says where to look, not what is there.** It found the
constructs no test reached; it could not tell that three of them were wrong, and
a construct that is wrong while fully covered is invisible to it by
construction. That is 3c's job.

### 3c. DONE — `tests/differential.sh`, and it is a HOST sweep

The premise this section carried was wrong, and the wrongness is the useful part:
it said "the Ada side needs the **guest** toolchain, so this runs in the guest".
It does not. The Ada side's output is Ada source, and that source's **entire**
runtime dependency across the corpus is `Aegir_User.Console` — three
subprograms — because the builtin modules are emitted as pure Ada (Convert.ToInt
converts a string by hand) and `Out` is inlined into Console calls. Measured
with `grep -ho 'Aegir_User\.[A-Za-z_.]*'` over the emitted units of every
fixture. So `tests/ada_host/` supplies those three on the host, and the whole
differential — 59 fixtures, both backends, three-way compare — runs in **14
seconds** with no QEMU, no cross-compile and no initrd.

That reframing is the point. A check that needs a guest boot per fixture would
never have run often enough to be worth having; at 14s this is a suite.

**THE THREE-WAY COMPARISON is the design**, and it is why a two-way diff of the
backends would be worse. There are three numbers, not two:

    golden   the expectation, checked in
    ada      what the Ada backend's OWN output does when run
    vm       what the bytecode image does when run

    ada == golden, vm != golden   ->  THE VM IS WRONG       (a bytecode bug)
    vm  == golden, ada != golden  ->  THE GOLDEN IS SUSPECT
    all three differ              ->  look; possibly a front-end bug
    all three agree               ->  the golden is CORROBORATED

And that is exactly what the section asked for: it distinguishes "the VM is
wrong" from "both differ from the golden" by construction, rather than by
reading a two-way diff.

**What it found, on its first run.** Zero VM bugs and zero wrong goldens — the
good news, and now evidence rather than hope:

    corroborated by both backends : 41
    VM wrong                      :  0
    golden suspect                :  1   (withguard - see below)
    ada refused (its own gap)     : 10   (Threads; procedure values)
    ada emits Ada that won't build:  7   (see below)

So every disagreement in the corpus is the ADA side failing, not the VM. Seven
fixtures make the Ada backend emit Ada that does not compile — a name colliding
with a declaration (`gcscalar`, `recmix`, `recreal`), a component used before
its record ends (`nested`), a type name that does not denote a type (`list`,
`newloop`), and one `expected type Boolean` (`realarr`). Those are Ada-backend
bugs, and the Ada backend is being retired, so they are **recorded** in the
script rather than fixed.

**It also caught a regression of its own making** — which is the strongest
argument for having it. The `by -1` fix (3f) started emitting the step's source
text into the Ada, and Ada rejects `i := i + -(1)` ("parentheses required for
unary minus"). Nothing else in the repo writes a descending `by`, so nothing
else could have noticed; the differential found it on the run that introduced it.

**`withguard` is the one golden suspect, and it resolved to the Ada side being
wrong.** The fixture guards a `P` (base) as its extension with a body that never
mentions the guarded variable. The VM and the golden print `425` — the body is
**skipped** — and the Ada side prints `4295`, running it. Oberon's `WITH` is a
*conditional* region: the body runs only if the guard holds, and the trap
belongs to the `v(T)` designator form (which is separate, and already tested by
the VM's `guardbad`). So the VM and the golden are right and the Ada side does
not implement the guard at all. The classification flagged exactly the right
fixture, and the investigation settled it.

**It is a GATE, not a report.** Every non-corroborated outcome must be a
RECORDED, reasoned Ada-side limit: an unlisted disagreement FAILS (so a new one
cannot appear quietly), and an entry that stops applying FAILS too (so the list
cannot outlive its cause). Verified by tampering — mis-recording one entry's code
and adding a bogus entry for a corroborated fixture produced exactly the two
expected failures, with nothing else.

Coverage finds what no test reaches; the differential finds what a test reaches
but the VM gets wrong. **Neither alone is enough** — that is the whole finding,
and it is argued at length in `docs/bytecode-gaps.md`.

### 3d. RE-SIZED — measured, and the sizing above is WRONG

The section below says this item was "declared **sized** rather than open".  That
sizing is disproved, and this note is its correction - the deliverable of the
attempt, not a fix.

**What the item actually requires.**  A user program must be able to CALL
`Files.Old`/`New`/`Read`/`Write`/`Close` - procedures of an imported module.  That
is a **cross-module call**, and bytecode has never had one:

- before this attempt, a call into an imported module was refused
  (`X.y is not yet supported`), which is why nothing in the corpus - 48 fixtures,
  all main modules with local procedures - ever exercised it;
- making the callee's code exist in the image (scoping the module) is necessary
  but NOT sufficient.  The call is emitted, its id/target/arity are all correct
  (3t), the argument provably ARRIVES (u5), and the value comes back WRONG (u6) -
  while every equivalent LOCAL shape works (e1/e2/e3: field offsets 0 and 64, via
  parameter, via return, `new`, `len`, `ARRAY OF CHAR` indexing).

So the gap is **how a value crosses a module boundary**.  It is not
Files-specific: it would bite any imported call.

**Sizing, honestly.**  This is the same class as the record/type coverage that
`samples/hello.ob2` refuses at - 530 lines, 18 imports, refused at its `type`
block - i.e. **milestone** work, not wiring.  The mistake was treating it as
wiring and working it probe by probe; the correct output of that discovery was
this note, on the first day.

**Reproductions, kept here because no harness can hold them.**
`bytecode_gaps.sh` records constructs that REFUSE; this one compiles and answers
wrongly, so nothing machine-checked can pin it.  Three small main modules:

    (* u5: is the argument even received?  Old on a missing path stores -1,
       New stores 0.  SAME Length for both => the argument is ignored. *)
    f1 := Files.Old("/tmp/o2c_u5_absent.txt");
    f2 := Files.New("/tmp/o2c_u5_created.txt");
    n1 := Files.Length(f1); n2 := Files.Length(f2);   (* measured: different -> arrives *)

    (* u6: the values themselves.  Correct is -1 and 0. *)
    (* measured: n1 NONNEGATIVE, n2 NONZERO - both wrong, and they differ *)

    (* e3: the field is NOT at offset 0.  FileDesc = record name: A64;
       size: longint end, so size is at 64 - and every earlier probe put its
       field first, which is why this case was never covered.  Measured: ok. *)

**State now.**  `Files` is NOT scoped (`Compiled_Builtin (... Scoped => False)`
with the reason in the source), so a user call refuses LOUDLY rather than
answering wrongly - the hazard that scoping otherwise creates, as the Math entry
above describes.  Everything the attempt fixed stays landed and gated: the
body-frame balance, the `R.Typ` clobber, the argument double-push, `LEN`, and
`ARRAY OF CHAR` indexing - five real bytecode gaps, with `lenopen` as a new
fixture and 48 fixtures corroborated by both backends.


### 3d. `Files.Old` / `Read` / `Write` / `Close` / `New`

Deferred, and it was declared **sized** rather than open. Measuring it corrected
the sizing in two places, and the correction is the useful part — the original
claim is kept below the marker so the error is not repeated.

**What the measurement changed.** The claim was "every statement in the module is
already supported… the only non-bytecode parts are the FFI primitives". Two
*data* gaps sat in front of the FFI wiring, and both are now fixed (3g):

- **`p^.field[i]` — an array field reached through a pointer — was refused**, and
  not only for `Files`: any program doing it failed. The message blamed the
  array's length; the length was fine and the address was wrong.
- **A `LONGINT` record field was refused**, because the allowed-type list omitted
  it. `Files.FileDesc` is exactly `name: A64; size: longint`, so the module could
  not even have its own types laid out.

So the real sequence for 3d is: (1) those two — **done, see 3g**; (2) the ~12
intrinsics (`FStat`/`FRead`/`FWrite`/`FClose`/`FDel`/`FRename`, `EnvGet`/`EnvSet`,
`ArgGet`, `PlaneOpen`/`PlaneClear`/`PlaneDot`, `InReset`/`InString`/`InName`)
as bytecode native calls — several counterpart natives already exist from the FFI
work; (3) the ordering change below.

**The next wall was** `Files.Open`'s `r.f := f` — an assignment to a **pointer
field** — which said "assigning through a pointer designator is not yet
supported". **That is now fixed too (3h)**, and the measurement has moved on:
`Files` gets past its types and its statements and stops at **LONGINT**, which is
where step 2 of the sequence starts (the ~12 intrinsics, several of which compute
in LONGINT).

And one thing the sizing missed entirely: **no fixture consumes any of it yet.**
The three data gaps above were worth fixing on their own merits (all three are
user-visible), but the rest of 3d is capability with no caller.

The original sizing, kept for the record:

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
coverage — descending FOR was exactly that case (3f), and it is 3c's job to
catch the next one.

### 3f. DONE — descending `FOR` (`by -1`), and two reasons it was unreachable

A descending loop could not be written at all, and the diagnosis in the previous
version of 3b had the wrong culprit: it indicted `for i := 3 to 1`, which
running its body zero times is *correct* Oberon-2 — a descent needs an explicit
negative step. The bug was that the step could not be given one.

**Two walls, one behind the other**, which is why it looked like a semantics
question rather than a parse question:

- `Parse_For` validated the step by scanning its Ada **image** for digits. Unary
  minus wraps the literal as `-(1)`, so `by -1` failed on the `(` — and the scan
  even allowed a leading `-` on purpose, so it was a bug in the check, not a
  missing feature. It also refused `by SOME_CONST`, whose text is a name.
- Behind it, `O2c_BC.For_Enter`/`For_Next` wrote the step with
  `Put_U32 (U32 (Step) and 16#FFFF_FFFF#)`. That mask never runs: a NUMERIC
  conversion of a negative `Integer` to `U32` raises `CONSTRAINT_ERROR` first.
  So nothing could have encoded a descent even once the parse succeeded — the
  failure surfaced as an exception inside the emitter, not as a diagnostic.

Fixed by taking the step from the parsed expression's **value**
(`B.Folds`/`B.Val`, which is what "integer constant" always meant) and encoding
it as a two's-complement bit pattern through an unchecked conversion from
`Interfaces.Integer_32` — the form the opcode's `i32 step` and the VM's decode
already assume. A zero step is now refused loudly, since it can never advance
the loop variable; a variable step is still refused, on the same rule as before.

The VM needed no change: `Op_For_Enter` derives the direction from from-vs-to
and steps by `abs (Step)`, so it supported descending all along.

`tests/bc/fordown.ob2` holds it: `by -1`, `by -2`, a negative `by` from a
`CONST`, a non-literal bound, ascending unchanged, the no-`BY` case (0
iterations, documenting the semantics above), and an iteration count. Every
descending case prints a wrong number rather than failing if the step arrives as
positive or zero. `run_bc.sh` also asserts the two refusals, so the relaxation
is shown not to be a free-for-all.

### 3g. DONE — the two data gaps that blocked `Files`, both refused by omission

Found by measuring 3d rather than by reading it: extract each scoped builtin out
of the compiler and compile it **in bytecode mode**. `Env`, `Args`, `XYplane` and
`In` failed on their intrinsics, as predicted — but `Files` failed *earlier*, on
its own types.

**1. An array field reached through a pointer — `p^.field[i]` — was refused.**
Not a `Files` detail: any program doing it failed, with

    bytecode error: an array needs a non-zero length

and the length was never the problem. The index path pushed a **globals** slot
while the object lives on the heap and its address was already on the stack;
`Total_Slots` of a POINTER is `0`, and the globals path rejects a zero-length
array, so the complaint landed on the array. Fixed by asking the question the
field path two branches up already asks — pointer base means *add this field's
byte offset to the address on the stack*, otherwise it is a run in the globals.
The message pointed at the wrong thing, which is why it read like a type
limitation and survived.

**2. A `LONGINT` record field was refused** — the allowed-type list simply
omitted `T_Long`. A list like that refuses **by omission**, and the diagnostic
named only the types that *were* allowed, so the missing entry was invisible.
That is the same mistake the assignment list had already been fixed for
elsewhere, with the same reasoning: LONGINT is a 64-bit slot, exactly like
INTEGER, so it needs no conversion and no new opcode. `Files.FileDesc` is
`name: A64; size: longint`, so it could not have its own types laid out.

`tests/bc/ptrfld.ob2` holds both by value (writes a byte-per-element array field
through a pointer, reads it back, then reads a LONGINT field after it), and
`bytecode_gaps.sh` asserts both compile at all — the part a golden cannot state.

**The next wall is now recorded rather than rediscovered**: `Files.Open` does
`r.f := f`, an assignment to a **pointer field**, which is the "assigning through
a pointer designator" refusal. `bytecode_gaps.sh` pins it as `blocked`, so step 2
of 3d starts from a known list.

Worth noting how the differential behaved here. `ptrfld`'s first version tripped
the Ada backend's case-collision bug (`type P` beside `var p` — Ada is
case-insensitive, Oberon is not), so the gate FAILED the run: a new,
non-corroborated fixture is exactly what it is for. That also fixed a **wrong
diagnosis** in the recorded list, which had logged those three entries as bare
name conflicts; they are now named as one category. The fixture was then renamed
to `Ptr` so it can be corroborated at all — both backends print `AC91` — rather
than adding a fourth instance of a known Ada-side limitation.

Two small process notes, both the same shape as earlier ones: the recorded list
gained its first commentary and the reader immediately parsed the comments as
fixtures named `# CASE is the cause ...` (now skipped), and `digits` is an Ada
reserved word.

### 3h. DONE — pointer fields, and the spelling that was unusable

The third and last of the data gaps in front of `Files`, and the one with the
most in it. **There are two spellings of a pointer field and only one was
recognised:**

    next: Node     a field whose type names its OWN record - the linked-list
                   idiom.  Nothing names the pointer, so the field carries the
                   RECORD's user type rather than a pointer's.
    f: File        a field declared with a NAMED pointer type.  This is what
                   Files uses, and it was not recognised as a leaf at all.

So `q^.next := p` worked while `r.f := f` and `h.p := q` were refused - one
construct, two spellings, one of them unusable. With no match the walk fell
through to the post-loop "the view is a pointer" case, which classifies the whole
designator as a bare pointer and hands it to the assignment path that refuses
designators by design - hence a message about *designators* for what is really a
missing leaf case.

**Four places had to agree, and the third is why this was not a one-line fix:**

1. The **leaf condition** must accept both spellings (a predicate,
   `Ptr_Field_Of`, now used in both places that ask the question).
2. `D.Ptr_Field` must be set for both, or the store uses the integer opcode on
   an address.
3. The **intermediate** case - walking *into* a pointer field - must load the
   pointer for both spellings.  Skipping it for the named one is not a refusal
   but a **wrong address**, so fixing only the leaf would have converted a
   refusal into a silent wrong answer, which is the trade this backend exists to
   refuse.  Fixing it then exposed a second bug in the same block: `Load_Fld_P`
   reads *from* the address on the stack, and a **record variable** base had
   never pushed one (a pointer base does, at the top of the chain), so `h.p^.n`
   came out as `operand-stack depth violation` until the base push was mirrored
   there.
4. The Ada-mode classification of a pointer leaf had to stay `D_Scalar` for the
   self-referential spelling and become `D_Ptr` for the named one.  `D_Scalar`
   carries no user type, so the named spelling needed `D_Ptr` - that is how
   `Files.Base*`'s `return r.f` was failing as "a pointer with no type" - but
   sending the self-referential spelling there instead turned list.ob2's
   recorded ADA_BROKEN into a pointer-type mismatch, a fresh failure in a
   fixture this change was not about.

`tests/bc/ptrfield.ob2` pins it by value (write a pointer into a field, read
through the field, NIL through it, re-point it) and both backends corroborate it.
`bytecode_gaps.sh` asserts all three shapes compile, including the linked-list
spelling the corpus depends on.

**How it was actually found, since the reasoning did not.** Four theories died to
measurement, in this order: the emitter blamed the array's length (wrong); the
first fix broke `Files.Base*` with "RETURN value type mismatch" (no types named,
so useless); naming the types said "a pointer with no type"; and a temporary
raise inside the walk printed `kind=D_Scalar ptr_field=TRUE d_ut=3`, which
located it exactly. The two RETURN messages now name the types they disagreed
about, permanently, because "mismatch" alone cannot distinguish the value being
the wrong shape from the TYPE having been recorded wrong. And
`D.K := (if D.Ptr_Field and then UTypes (...) ...)` is load-bearing, not
decoration: without `D.Ptr_Field and then` it indexes `UTypes (0)` and crashed on
every record with an INTEGER in it.

### 3i. DONE — LONGINT arithmetic, which was refused wholesale

The first thing step 2 needed, and a whole language gap. **Every** LONGINT
operator refused with one message — `+`, `-`, `*`, `DIV`, `MOD` and unary `-` —
while assignment and comparison worked.

That was a **precaution, not a limitation**: a LONGINT is the same 8-byte slot as
an INTEGER in this VM, so the integer opcode *is* the LONGINT opcode. The check
was written when that was not yet certain and never revisited — the same shape as
the record-field list in 3g, costing the same thing: a construct the language has
that one backend will not compile. Mixed INTEGER/LONGINT needs nothing either, as
`Int_Like` only mixes when the other side is a literal, and a literal is already
the wider type's slot.

`tests/bc/longarith.ob2` asserts each operator by **result**, because the existing
`longint.ob2` only ever assigned and compared — no test could have noticed. Its
last case is the point of a LONGINT: `1000000000 * 3` does not fit in 32 bits, so
anything quietly narrowed would print `WIDE-BAD`.

**What is left is the LITERAL, which is a different thing**, and is recorded so
it is not mistaken for the arithmetic gap again. A LONGINT literal above
`INTEGER'Last` cannot be written, because the parser types an integer literal as
INTEGER; the Ada backend accepts it, so this *is* a divergence — and it is why
`longarith.ob2` builds 3e9 by multiplication instead of writing it.

One entry in `bytecode_gaps.sh` had to change hands rather than merely be added,
which is that file working as intended: the assertion that unary minus on LONGINT
**refuses** is now an assertion that it negates, checked by value.

**Measured result:** `Files` gets past LONGINT too and now stops at
**`Files.FRename`** — an intrinsic. That is step 2's actual subject: what remains
is the ~15 intrinsic primitives, not anything about the language.

### 3j. DONE — two `ARRAY OF` parameter gaps, and the first two intrinsics

**The user-visible half first, because it was not about `Files` at all.**
`Out.String (s)` inside a procedure — `s: array of char` — failed with

    o2c error: bytecode emitter: operand-stack underflow

a message about the **stack** for a problem with a **string**, which is why it
read as an emitter bug rather than as an unimplemented case. Two things were
missing and both are about where an open array's bytes are:

- a bare `ARRAY OF CHAR` pushed **nothing**: the caller's address sits in the
  parameter's own first slot and nothing put it on the stack;
- `Out.String` on a CHAR array is an inline print **loop over a globals run**,
  and an `ARRAY OF` parameter is not in the globals — its `UT` is 0, because an
  open array has no type of its own — so the loop was skipped and the
  pool-string native ran on an address.

The same push also fixes **string comparison** between open arrays, which needs
two addresses. `tests/bc/arrparam.ob2` holds both by value, calling one
procedure with arrays of **three different lengths** so a stale bound prints the
wrong text rather than nothing.

**Then the first two intrinsics.** `FDel` and `FRename` refused in bytecode mode
even though their natives (`o2c_fdel` id 9, `o2c_frename` id 10) already exist —
their branches append to the Ada body only, which is *why* they refused: with no
`O2c_BC` call a bytecode program would have compiled, run, and quietly done
nothing. Both now emit the native call once their argument addresses are on the
stack. They are not reachable from a user module (the compiler gates them on the
`Files` module), so there is no source-level check to write and none was added:
what proves them is the **module** compiling, which is the measurement this whole
sequence runs on.

**Measured result, and the state of the path:** `Files` gets past both, and now
stops at

    o2c error: bytecode backend: '&' is not yet supported

— `Files.Wait`'s `while (i < 400) & (FStat (path) < 0)`, the BOOLEAN `&` that
`bytecode_gaps.sh` already records as *blocked*. So what remains is: the BOOLEAN
operator opcodes, then the four natives (`FStat`/`FRead`/`FWrite`/`FClose`),
after which the module compiles and step 3 (the `Begin_Mode` ordering) is the
last thing between it and a program that calls `Files.Old`.

### 3k. DONE — BOOLEAN `&`/`or`, a crash on a module with no body, and the silent four

Three things, in the order they surfaced.

**BOOLEAN `&` and `or` had no opcode.** Both refused loudly (`'&' is not yet
supported`, `BOOLEAN operators are not yet supported`) while the spec had
reserved `0x72–0x7F` for exactly this, immediately after `BEQ`/`BNE`/`BTEST`.
They take the first two of that block — `BAND` 0x72, `BOR` 0x73 — so nothing is
renumbered and a BOOLEAN operation sits with the BOOLEAN operations. The `Op`
enum member still goes at the **end** of the enum: that order is fixed and
separate from the byte mapping, which is what makes the reserved block usable at
all. The operands are tested against ZERO rather than against 1, so the answer is
right for any truthy value, and the result is canonical 0/1. Both are strict —
the operands are already evaluated, so there is nothing to short-circuit.
`tests/bc/boolops.ob2` asserts seven cases by value, the last of which crosses
this change with the earlier `not` fix (`not (a & b)`).

**A module with no statement part crashed the emitter.** `Files` is written that
way — declarations and `end Files.` — and `Begin_Body` was called only when a
`BEGIN` was found. `Body_Proc` stayed 0 and `Encode` indexed the procedure table
at 0: a `CONSTRAINT_ERROR` inside the emitter, not a diagnostic, on a construct
the language allows. The body is now opened unconditionally, because a body with
no statements is still a body and the image still needs an entry.
`tests/bc/nobody.ob2` locks it, with an intentionally empty golden: what is being
asserted is that it compiles and runs.

**And then the discovery that matters most.** With those two fixed the whole
`Files` module **compiled** — and that was wrong. Four of its intrinsics
(`FStat`, `FRead`, `FWrite`, `FClose`) set a type and emitted **no opcode at
all**, so a bytecode program would have compiled, run, and used whatever was on
the stack — in practice the ADDRESS the argument had just pushed. Nothing
refused, because the default-refusal rule covers imported-module *calls* and
these are internal primitives of the builtin module: a different shape of call
site. They now refuse loudly until they have natives to call, which is what
`docs/bytecode-gaps.md` A.2 records. **A module compiling is not evidence that it
is right**, and this is the second time that lesson has been paid for.

**State of the path:** `Files` refuses at `Files.FStat` — the first of the four
natives still missing (ids 26–29: `o2c_fstat`, `o2c_fread`, `o2c_fwrite`,
`o2c_fclose`, each needing a `VM_Platform` seam function in the spec **and both
bodies**, host and Aegir). After those, the module compiles, and step 3 (the
`Begin_Mode` ordering) is what makes it callable.

### 3l. DONE — the four natives, and the Aegir trap sprung for real

`o2c_fstat` (26), `o2c_fread` (27), `o2c_fwrite` (28) and `o2c_fclose` (29),
appended after the input group with their arities and their "returns a value"
flags, plus four `VM_Platform` functions in the spec and — the part that
matters — **both** bodies.

**The trap was sprung, and only `run_m1` caught it.** Three host suites passed
with the Aegir body missing a `use type Interfaces.Unsigned_64;`, so the guest
build failed on operators that were not directly visible:

    vm_platform.adb:92:43: error: operator for type "Interfaces.Unsigned_64"
    is not directly visible

That is exactly what the trap list predicts — the three host suites cannot see
this file — and it is worth recording that the prediction held.

**The natives are verified BY EFFECT**, not by compiling. The intrinsics are
gated on the module being `Files`, so `tests/bc/filesintr.ob2` IS a module named
`Files`, which is what makes them reachable at all:

    absent      FStat on a path that was just deleted reports -1
    write=0     FWrite puts a byte at offset 0
    size=1      ... and Stat then reports ONE byte, read from the filesystem
    read=0Q     FRead replaces a buffer holding something else, and what it
                reads is the byte that was written
    close=0

`read=0Q` is what makes it a real test: the buffer held `z` first, so a read
that did nothing would print `z`. The file is deleted first, so "absent" is a
fact rather than an assumption, and deleted again at the end, so the fixture is
hermetic and idempotent.

**That fixture is deliberately bytecode-only.** A user module named `Files` gets
the intrinsics but not the emitted `O2c_F*` helper BODIES, which live only in the
builtin module — so its Ada output references helpers it does not define. The
differential flags it, and it is recorded with that reason rather than hidden:
the fixture's subject is the four natives, and the VM side verifies them.

**State of the path:** the whole `Files` module compiles to bytecode with real
native calls, and the four primitives are verified by effect. What is left of 3d
is **step 3** — the `Begin_Mode` ordering — which is what lets a *user* program
call `Files.Old`/`Read`/`Close` rather than only the module compiling.

### 3m. DONE — the body frame, the ordering, and bytecode builtins

**The root cause was an asymmetric begin/end pair**, and finding it took three
diagnoses, two of them wrong.  Recording the wrong ones because they are the
trap: (1) "the export record carries no bytecode id" - plausible, wrong;
(2) "main-module vs library compilation" - wrong; (3) the trace.

What the refusal said once it NAMED the procedure:

    bytecode backend: call to an unknown procedure 'Bracket'

`Bracket` is `Term`'s first procedure.  Instrumenting `Decl_Procedure` and the
call site showed it gets no id at all while the second and third procedures do:

    TRC reset bytecode=TRUE
    TRC call 'Bracket' idx= 9 bcproc= 0 n_sym= 11
    TRC decl 'Ch'     idx=10 id=50
    TRC decl 'Clear'  idx=11 id=51

The id is assigned only when

    if O2c_BC.Bytecode_Mode and then not O2c_BC.Proc_Open then

and `Proc_Open` is not a mode flag - it is frame state:

    function Proc_Open return Boolean is (Cur_Proc /= 0);

`Begin_Body` opens the module body's frame (`Body_Proc := Begin_Proc (0, 0)`) and
**nothing ever closed it**.  So the next module's FIRST procedure saw the frame
still open, skipped `Begin_Proc` - and its `end` still called `End_Proc`, which
is unconditional (`o2c_compiler.adb:6176`).  That closed the leaked frame, which
is why the damage healed from the second procedure on.  One procedure per module
lost its id, and its first call site is where it surfaced.

**Why it was invisible until the ordering changed**: `Begin_Mode` calls `Reset`,
which wiped the frame, and `Begin_Mode` used to run after the builtins and just
before the main module.  The ordering change did not break the main module - it
exposed a leak that had always been there, hidden by `Reset`.

**The fix** is two pieces, both landed here:

1. `O2c_BC.End_Body`, the matching close for `Begin_Body`, called at the START of
   every module compile.  At module start no procedure frame can legitimately be
   open, so this is exactly the missing balance.  It closes the BODY frame only
   (`Cur_Proc = Body_Proc`) - a procedure frame left open is a different bug and
   closing it here would hide it.
2. The ordering change, now working: `Begin_Mode` before the builtins, a
   `Scoped` flag per module, the main module switched on afterwards.

**The scoped set is measured, not chosen** (each module compiled alone, bytecode
mode, library shape):

    scoped (compile)   Texts, Files, Math, Term, MathL, Err
    emitter gap        Strings, Reals, Input   (operand-stack underflow)
    intrinsic sites    Env, Args, XYplane, In, Convert - whose natives
                       (6/7/8, 11-21) already exist and need only the wiring
                       the Files intrinsics got in 3l

A builtin left out costs nothing: every module is parsed and its Ada text emitted
either way, so `Scoped => False` is exactly the old behaviour.

**Verified**: `sum` compiles (5504 bytes, the scoped builtins' code is now in the
image) and RUNS CORRECTLY - `bc slice ok` / `406`, the sum of 1..28 - where it
used to fail with `call to an unknown procedure 'Bracket'`.  All seven suites
green, 47 corroborated by both backends, zero warnings.

**What is left of 3d**: a USER program calling `Files.Old` now reaches a clean,
explicit refusal rather than confusion -

    o2c error: bytecode backend: Files.Old is not yet supported

That is the FFI default-refusal allowlist, and it is the last step: let a
qualified user call resolve to the procedure that is now IN the image, through
the export record (`X_Entry`), which is where a bytecode id must travel between
modules.  (`X_Entry` genuinely has no such field - it was the right fix, just
not the cause of the regression.)

### 3n. DONE — the bytecode id crosses the module boundary

A qualified call to an imported procedure now resolves to the procedure that is
in the image, and the piece that carries the id is the export record:

    type X_Entry is record
       ...
       Bc : Natural := 0;      --  the bytecode procedure id, when the code is
                               --  in the image (0 = not compiled to bytecode)

`Bc /= 0` IS the signal a call site uses: the factor path pushes the actuals with
`Bc_Push_Arg` and calls `O2c_BC.Call_Proc (Xs (XI).Bc)` when the id is there, and
keeps its loud refusal when it is not.  `Files.Old` went from

    bytecode backend: Files.Old is not yet supported

to an actual call.

**One trap here is worth its own line**: the export has to read the procedure's
OWN symbol index, and `N_Sym` is NOT it by then - a parameter interns a symbol
while the heading is parsed.  Reading `Syms (N_Sym).Bc_Proc` gave 0, and the
trace of the two sides is what showed it:

    TRC SET 'Old' n_sym= 1 id= 8      <- the id IS assigned, to symbol 1
    TRC EXP 'Old' n_sym= 2 bc= 0      <- the export read symbol 2

Hence the `PSym` local, set where the procedure's symbol is created.

**And the finding that matters more than the feature:**

    "COMPILES CLEANLY" IS NOT THE STANDARD FOR SCOPING A MODULE.

Six modules compile to bytecode cleanly.  A construct with no emission does not
refuse - it leaves whatever is on the stack, and the callee runs WRONG in
silence.  Math is the counter-example, and only *calling* it found it:

    procedure sin(x: real): real; begin return Sin(x) end sin;

The builtin `Sin(x)` is emitted as Ada text only, so a scoped Math returned its
own argument - `sin(1.5)` printed `1.500`, with no error anywhere.  Verified by
making the call, before narrowing.

So the scoped set is now **Files alone**: 3d needs it and it is the one whose
bodies have been verified by effect (`tests/bc/filesintr.ob2`).  Everything else
is `Scoped => False`, which costs nothing - every module is parsed and its Ada
text emitted either way - and a user call into one keeps its loud refusal.
`Math.sin` is back to `Math.sin is not yet supported` rather than a wrong number.

**Verified**: `sum` compiles and runs correctly (`bc slice ok` / `406`); a user
call to `Files.Old` emits a real call; `Math.sin` refuses loudly; all seven
suites green, 47 corroborated, zero warnings.

**What is left of 3d**: two things, both now named.  (1) A qualified user call to
`Files.Old` is blocked one step past the call by an unrelated limit -
`pointer type mismatch assigning f`, imported pointer-type identity - so the call
cannot yet be verified by effect from a user module.  (2) The STATEMENT path
(`Files.Read`/`Write`/`Close`/`Register`) still refuses; it needs the same
treatment the factor path just got.


### 3o. IN PROGRESS — the first cross-module call with an open-array formal

Attempting the end-to-end check (`f := Files.Old(nm)` then `Files.Length(f)`)
surfaced two things, both measured, neither landed yet.

**1. `X_Ret_UT` is not `Import_Type` for this case.**  The factor path already
resolves a pointer result with `R.Ptr_UT := X_Ret_UT (XI)`
(`o2c_compiler.adb:3519`), and the assignment still fails:

    o2c error: pointer type mismatch assigning f

Replacing that with `Import_Type (Owner, Member)` - split out of the qualified
`Xs (XI).Ret_Nm` - makes the assignment type-check.  So for a POINTER result
whose target is a RECORD type of the exporting module, `X_Ret_UT` does not
produce the id the assignment needs, and `Import_Type` does.  That part is
understood and worth keeping.  (It does NOT fix the next problem.)

**2. The image is then malformed at verification.**  With the assignment fixed,
the program compiles (2400 bytes) and the VM rejects the image:

    vm: internal error in phase 3: STORAGE_ERROR (stack overflow or erroneous
    memory access)
    vm: malformed code

Prime suspect, and it fits the evidence: **`Files.Old`'s formal is an OPEN ARRAY**
(`Old(name: array of char)`), which travels as TWO slots - the address and the
length - while the factor call path pushes one value per actual.  That path was
modelled on the FFI sites (`XYplane.IsDot (x, y)`), which take only scalars, so
an open-array actual has never been exercised through it.  The statement path and
the local call path both know about the length slot; the factor path does not yet.

**Next step, in this order:** push an open-array actual as (address, length) on
the factor path the way the local call path does, then re-run the end-to-end
check.  Note `Files.New` has the same formal shape, so the same fix serves both,
and `Files.Length(f)` - a pointer argument, one slot - is the control case that
should pass immediately once the open-array actual is right.

The tree is left at the verified commit; none of the above is committed.


### 3p. DONE — both blockers were one mistake, and what is left is inside the callee

The two findings in 3o turned out to be facets of the same error, and the
diagnosis in 3o was right about the shape but wrong about where the fix goes.

**1. `R.Typ` was being clobbered.**  `X_Ret_UT` ALREADY calls `Import_Type`
(`o2c_compiler.adb:586`) and the factor path already sets
`R.Typ := T_Ptr` with it (3518-3519).  The new call emission then set

    R.Typ := (if Xs (XI).Ret then Xs (XI).Typ else T_Int);

which OVERWROTE that with the export's scalar sentinel - and that is what
produced `pointer type mismatch assigning f`.  My hand-rolled replacement looked
like the fix only because it set `R.Typ := T_Ptr` again.  The fix is to set
nothing: the type was already right.

**2. The open-array actual was pushed twice.**  `Parse_Actual` pushes an OPEN
formal's address AND its length itself (`o2c_compiler.adb:2294`, `2295`, `2308`),
and in that branch only.  The factor path then pushed `Bc_Push_Arg` on top, one
value too many.  Guarded now:

    if not X_Formal (XI, K).Open then
       Bc_Push_Arg (Arg_R (K));
    end if;

This is why the FFI arms never hit it: `XYplane.IsDot (x, y)` and `Dot (x, y,
mode)` push their scalars by hand and have no open formal.

**What is left, and it is a different bug.**  With both fixed the program
compiles and the VM now reports a specific internal error instead of a vague one:

    vm: internal error in phase 3: CONSTRAINT_ERROR (obc_vm.adb:2129 range check
    failed)

Line 2129 is `Top`'s `return Stack (SP - 1)` - an OPERAND-STACK UNDERFLOW during
execution, so a balance inside the CALLEE.  The call itself works (`sum` passes,
and the call site is reached); what is unbalanced is a construct in `Files`'
bodies that no fixture has ever exercised - the candidates in `Old` are
`new(f)`, `len(name)` on an open array, and `f^.name[i] := name[i]`, the nested
array-field-index store.  Each is a small, separately testable construct, and
that is where to look next: a fixture per construct, not a Files-shaped one.

So the sequence for 3d is now: exercise those constructs directly, fix whichever
is unbalanced, then the end-to-end check (`Files.Old` + `Files.Length`) should
pass - `Files.Length` being the one-slot control case.


### 3q. DONE — LEN; and the bisect that found it

The underflow in 3p was `LEN`, which had **no bytecode emission at all** - only
Ada text was produced:

    if Eq_No_Case (Cur.Text (1 .. Cur.Len), "LEN") then
       ...
       R.Text := To_Unbounded_String (LNm) & "'Length";
       R.Typ  := T_Int;                --  and nothing pushed

So `i < len (name)` left the comparison a value short, and the VM rejected the
whole image:

    vm: internal error in phase 3: CONSTRAINT_ERROR (obc_vm.adb:2129 range check
    failed)          --  Top's "return Stack (SP - 1)", an operand-stack underflow

**Where the length lives depends on the array**, which is why one emission is not
enough: a known-length array's length is its declared one (a constant at the use
site), and an `ARRAY OF` parameter's length is the CALLER's, in the parameter's
second slot (the `#alen-` slot the parameter linkage interns).  Both cases are
emitted; anything else refuses.

**The bisect is the reusable part.**  The constructs in `Files.Old` were tested
one at a time, as local procedures in main modules with no Files involved:

    c1  new(f) + f^.name[0] := "x" + read back ........ works
    c2  len(name) on an OPEN array .................... MALFORMED  <- this one
    c3  f^.name[i] := name[i] ......................... runs, copies NOTHING
    d1  f^.size := 7 through a pointer, read back ..... works
    d2  f^.name[i] := nm[i] from a GLOBAL array ....... works
    d3  read name[0] / name[i] of an OPEN parameter ... prints BLANKS

Each is a main module with no imports, so a failure cannot be about the call, the
module boundary or the builtin - only about the construct.  `c2` was the first
failure and the fix above is its fix.

**Fixture**: `tests/bc/lenopen.ob2`.  Its last two lines call the same procedure
with arrays of DIFFERENT lengths; a length taken from the declaration instead of
from the caller would pass the first two lines and fail those - which is the
point of writing it that way.  It is corroborated by BOTH backends (48 fixtures
corroborated now, up from 47): the Ada side and the VM agree on all four numbers.

**Still broken, and it is what breaks `Files.Old`** (which copies `name[i]` into
its record): reading an element of an `ARRAY OF` parameter - `d3`, constant and
variable index alike - prints blanks, in SILENCE.  `d2` shows it is specific to
the open array: the same store from a global array works.  So the next step is
the open-array element READ, and `d3` is its minimal reproduction.


### 3r. DONE — indexing an ARRAY OF CHAR (and a correction)

**Correction first, because 3q stated it too broadly.**  "Reading an element of
an ARRAY OF parameter is silently broken" was wrong, and a fair question exposed
it: `openarr.ob2` has indexed an open-array parameter all along -

    procedure Sum6 (a: array of integer): integer;
       for i := 0 to 5 do s := s + a[i] end;

- and it passes.  So do passing an open array, printing one with `Out.String`,
and (after 3q) taking its `len`.  Open arrays were working.  What was missing was
narrower: **indexing an `ARRAY OF CHAR`**.

**The cause** is a branch of its own that built only the Ada text:

    if Syms (Id).Typ = T_Char then
       if Cur.Kind /= Lex.Tok_LBracket then <bare string value ...> return R; end if;
       Next;      --  past '['
       R.Text := To_Unbounded_String (Nm) & " (" & Ix.Text & " + 1)";
       R.Typ  := T_Char;
       return R;                    --  and NOTHING was pushed
    end if;

The `+ 1` is there because a CHAR element is 1-based in the emitted Ada, while an
INTEGER array is not - which is exactly why this branch existed, and exactly why
it never reached the array path below it that knows how to EMIT.  In bytecode
mode `name[i]` therefore pushed nothing, the surrounding expression was a value
short, and the character read as blank - silently.

**The fix**: the bare-value shortcut now applies only when there is no `[`, so an
indexed CHAR access falls through to the shared array path (base load, bounds
check against the length that travelled with the array, then `Load_Idx_B` - the
same path that made the INTEGER case work).  The Ada text keeps its `+ 1`.

**Verified**: `d3` prints `abc` (constant and variable index), `c3` prints `ab`
(the store from an open-array element), the `Old`-shaped probe prints `abc`,
`openarr`'s image output is byte-identical to its golden, all seven suites green,
48 corroborated, zero warnings.  (Introducing a duplicate `return R;` on the way
warned as unreachable code; it was removed - zero warnings is not optional.)

**Next, and narrower again**: the end-to-end check now says `Files.Length` does
not report 0 for a file `Files.New` just made ("NOT zero" from `/tmp/probe/u3.ob2`).
That rules out what `Old` stores and points at what travels BACK across the module
boundary - a LONGINT result, or the pointer argument - rather than at any
construct inside the callee.


### 3s. IN PROGRESS — the fault is the cross-module CALL, not the constructs

The end-to-end failure is now pinned to the call, by elimination rather than by
argument:

    e1  Files.New + Files.Length rewritten as LOCAL procedures ... "local: zero"
    u3  the same code called across the module boundary ......... "NOT zero"

Same source, same shapes - `new(f)`, `f^.size := 0`, `len(name)`, the open-array
element copy, `f^.name[i] := name[i]`, a pointer return, a pointer parameter, a
field read through that parameter - and it works when the callee is local.  So
every construct inside `New` and `Length` is fine, and so is the result/parameter
machinery in general.  What breaks is calling them ACROSS the module boundary.

**The one thing measured about that call:** the unqualified call path emits its
call with NO argument code of its own (`o2c_compiler.adb:9266-9288` - just
`Call_Proc` or `Native_Call`), because `Parse_Actual` has already pushed the
actual: the value, or for an OPEN formal its address and length.  The qualified
path I added also pushed with `Bc_Push_Arg`, i.e. a second copy of every scalar
argument.

**Removing that second push did NOT fix the symptom** - `u3` still says "NOT
zero" - so the extra push is not the cause, and the change was reverted rather
than landed on reasoning alone.  It is still the right shape on the evidence
(the local path is the reference implementation and it pushes nothing), but a
change that alters nothing observable and is covered by no test is not a commit.

**Next, and it is a narrow question now**: is the CALL TARGET the right
procedure?  `Call_Proc` patches its operand from the fixup table at Encode, and
the id it is given is `Xs (XI).Bc`, captured when the exporting module was
compiled.  A wrong target would explain a callee that runs, returns a value and
returns the WRONG one without trapping - which is exactly what is observed.
`Proc_Entry` (`o2c_bc.adb:81`, filled in `Begin_Proc` at 677) is where to look,
and a trace of the target's identity at the call site is the cheapest way to
settle it.


### 3t. IN PROGRESS — what the cross-module call is NOT

`3s` asked whether the call targets the right procedure.  It does.  Tracing both
sides settles it:

    DBG decl 'New'    id= 2         (Files, declaring side)
    DBG decl 'Length' id= 3
    DBG call 'Files.New'    id= 2 npar= 1
    DBG call 'Files.Length' id= 3 npar= 1

The ids match, and so do the arities: `New` needs 2 slots (its `array of char`
formal is open) and the emitter records 2, `Length` needs 1 and the emitter
records 1.  So the id, the target and the argument COUNTS are all right.

**Two probes narrowed it further, and they disagree in an informative way.**

    u3  f := Files.New(nm); n := Files.Length(f);     runs, returns GARBAGE
    u4  n := Files.Length(Files.New(nm));             image is MALFORMED

`u3` stores a call's result in a variable and reads it back later; `u4` never
stores it - the inner call's result goes straight in as the next call's argument.
`u4` being malformed means the fault is in the CALL RESULT as an operand, not in
the assignment; and it is a verifier-visible stack/arity violation, which is a
much better clue than a wrong number.

**One oddity worth its own note**, found while looking for a depth invariant to
test: `Depth` (`o2c_bc.adb:95`) is reset by `Reset` and never at a procedure
boundary, so readings taken inside different procedures are not comparable, and
the per-image `Max_Depth` written at `o2c_bc.adb:1038` accumulates across the
whole compile rather than per frame.  That is not the cause of anything above,
but it means the emitter's own depth accounting cannot be used as the check it
looks like, and any debugging that assumes otherwise will mislead.

**Next**: the call RESULT as an operand.  `u4` is the reproduction, and it is
smaller than `u3`: no assignment, no variable, two calls.  What to compare is the
code the qualified path emits around `Call_Proc` versus the unqualified path
(`o2c_compiler.adb:9266-9288`), which emits nothing but the call because
`Parse_Actual` has pushed everything - including, for an actual that is itself a
CALL, the value that call already left on the stack.


### 3u. DONE — the duplicate push, and where the chase stops

`e2` was the probe that settled the shape of the problem: `u4`'s code (one call's
result used as the next call's argument) with LOCAL callees prints
`local nested: zero`, so nesting is fine, results-as-operands are fine, and the
difference is the qualified path's own emission - which is mine, and about
thirty lines of it.

The one structural difference was that it pushed `Bc_Push_Arg` for every actual
**in addition to** what `Parse_Actual` had already pushed.  The local call path
(`o2c_compiler.adb:9266-9288`) emits its `Call_Proc` with no argument code at all
precisely because `Parse_Actual` pushes - the value, or for an OPEN formal the
address and its length.

**Removing it is a real fix, measured on two cases rather than one:**

    u4  before: "vm: malformed code"      after: runs
    u3  before: garbage                   after: garbage

A rejected image became a running one.  (The earlier attempt at this same removal
was measured on `u3` alone, which is exactly how a real fix gets reverted as a
non-fix - and it was.  Measuring both is what makes it one.)

**What is left is a different class**, and it is where I stop chasing:

    u4 / u3 / useold2 all RUN now, and all return the WRONG VALUE

Since the call now pushes exactly what the local path pushes, the remaining
difference between a local and a qualified call is the FORMAL DESCRIPTOR.
`X_Formal` (`o2c_compiler.adb:562-575`) rewrites an imported formal whose exported
type is a user type into `F.Typ := T_Int` with `F.UT := Import_Type (...)`, so
`Parse_Actual` is handed a formal that looks scalar-with-a-user-type.  A pointer
pushed through that route - truncated to an integer width, or pushed as an
address rather than as a value - would give a callee that dereferences something
valid-looking and returns a plausible wrong number, with no trap.  That is the
next hypothesis, and `u3` is its reproduction.

**The stopping rule this section exists to state**: if a probe does not shrink the
reproduction or eliminate a hypothesis, stop and switch to natives rather than
chase.  This iteration shrank it (a rejected image became a running one), so it
continued; the next one has to do the same or 3d switches to making the rest of
the Files API FFI natives, as `Delete` and `Rename` already are.


### 3v. HYPOTHESIS TESTED AND DEAD — and the switch the stopping rule triggers

The bounded iteration on the formal descriptor (`3u`'s hypothesis) was run, and
it is **disproved**.

Measured first, which is what made the hypothesis look right:

    u3 (cross-module): PA in typ=T_INT  ut=4 open=FALSE
    e2 (LOCAL, works): PA in typ=T_STR  ut=3 open=FALSE

`X_Formal` was flattening a user-typed formal to `Typ := T_Int`, while the
identical LOCAL formal is described as `Typ = T_Str` with its user type - so a
pointer actual took the INTEGER route.  The change (described as the local case
describes it) was applied, and it does make the shapes match:

    u3 after:         PA in typ=T_STR  ut=4 open=FALSE     <- same as e2 now

and it changed NOTHING observable:

    u3  before: "NOT zero"      after: "NOT zero"
    u4  before: "NOT zero"      after: "NOT zero"

So the descriptor is not the cause, and the change was REVERTED rather than kept
on the strength of looking more correct - same standard as everywhere else: it
alters nothing observable and no test covers it.

**That is the trigger.**  `3u` states the rule: if a probe does not shrink the
reproduction or eliminate a hypothesis, stop and switch to natives rather than
chase.  The probe eliminated a hypothesis (worth keeping - nobody need tread it
again) but did not shrink the reproduction, and the iteration the user authorised
was explicitly "one more, bounded".  It is used up.

**The course from here is therefore the one chosen in advance**: stop scoping
`Files` and make the rest of its API (`Old`/`New`/`Read`/`Write`/`Close`/
`Register`/`Set`) FFI natives, the way `Delete`/`Rename` and the four positioned
primitives already are.  That removes the whole failure surface this section
documents: no Oberon bodies compiled to bytecode, no imported formal descriptors,
no cross-module value transport.  What it costs instead is VM-side file-handle
state, which is ordinary, testable work of the kind the existing 25 natives
already demonstrate.

Everything the chase produced stays valid and landed: the body-frame balance, the
`R.Typ` clobber, the argument double-push, `LEN` and `ARRAY OF CHAR` indexing are
real bytecode gaps closed, with `lenopen` as a new fixture and 48 fixtures
corroborated by both backends.


### 3w. TYPE COVERAGE — item 1, measured

Decision: type coverage first, because that is what a real program refuses at
BEFORE libraries or calls.  Scoped in public before any code, per the rule 3d
cost us.

**The boundary, read from the source.**  A variable declaration in bytecode mode
is accepted only if its type is a pointer, a procedure value, an array whose
element is `Int/Char/Bool/Real` with a non-zero length, or a record for which
`Chain_Fields_Allowed` holds (`o2c_compiler.adb:5279`, `Fields_Allowed` at 1286).
`Fields_Allowed` walks a record's fields, and for a field that is itself a
user type it accepts exactly three shapes: the record itself (Oberon's implicit
pointer), a POINTER, or a fixed array whose ELEMENT is a slot scalar
(`Int/Char/Bool/Set/Real/LReal`).  Nested arrays are outside it.

**Item 1, measured.**  The refusal now names the type it choked on - which is
what made this measurable at all, and is the same lesson as
`call to an unknown procedure`:

    o2c error: bytecode backend: non-INTEGER arrays, record extensions and
      records with non-INTEGER or user-typed fields are not yet supported
      ('Tote')

`samples/hello.ob2`:

    type Vector = array 4 of integer;
    type Mat    = array 2 of Vector;            <- element is an ARRAY
    type Tote   = record m: Mat; k: integer end;
    var  sac    : Tote;

So item 1 is **a record field that is an array of arrays**, and it refuses
correctly: the layout machinery carries one level of array-of-scalars, not two.
Everything else in the program's type block is already fine - `Vector`, `Pair`,
`Line`, `FLine`, the self-pointer chain `Node`/`NodeDesc`, and the local extension
`Circle = record (Shape)`.

**Named but NOT yet measured** (they come after item 1, so they cannot be
measured until it lands): `P3 = record (Geom.Point) z: integer end` - an
extension of an IMPORTED record - and whatever the refusal after that turns out
to be.  Marked as unmeasured rather than listed as known.

**The progress metric for this workstream**: `hello.ob2`'s refusal advances.
Each item that lands moves that message later in the program, so the checklist is
self-updating and the claim "item N is done" is checkable by anyone running one
command.  That is the shape this work should have had from the start.

**Item 1 is one level of array nesting in a record field.** The fixture that
pins it comes with the fix, not before: the work order is item, test, commit.


### 3x. ITEM 1 IS TWO HALVES — one measured, one not; attempt reverted

Attempted item 1 (record fields that are arrays of arrays) and **reverted it**,
because the attempt was half a fix and the half that was missing made things
worse in the way that matters.

**What the half proved.**  Two changes were needed and both were made - a
recursive `Total_Slots` (an array whose element is a user type is
`Arr_Len * Total_Slots (Elem_UT)` slots, not `Arr_Len`), the record-field rule,
and the declaration rule.  With them, the progress metric MOVED:

    hello.ob2 refuses at  'Tote'  ->  'Files.Rider'

So the layout half is real, and the checklist is now self-updating in practice
rather than in principle.  Item 2 is `Files.Rider` - an IMPORTED record.

**Why it still cannot land.**  The fixture that exercises two-level indexing says
so:

    type V4 = array 4 of integer;
    type M2 = array 2 of V4;
    var  m  : M2;
    (* for i in 0..1, j in 0..3:  m[i][j] := i * 10 + j;  then print *)

    expected:  0 1 2 3 10 11 12 13
    measured:  10 11 12 13 10 11 12 13

Both rows hold the same values, so the ROWS ALIAS: the first-level index stride is
0 or 1 where it must be `Total_Slots (V4)` = 4 slots.  The layout was fixed and
the ACCESS was not.  With the check open, that is not a refusal - it is a program
that compiles, runs, and answers wrongly, which is the one outcome this project
does not accept.  So the whole attempt was reverted rather than landing the size
fix unverified: with the check closed again, the size fix changes nothing
observable, and a change that alters nothing observable is not a commit.

**Item 1, restated with both halves named:**

    1a  size:   Arr_Len * Total_Slots (Elem_UT)          - known, one line,
                                                           measured to work
    1b  access: the first-level index stride, currently  - the missing half
                ignoring the element size

1a is recorded here so it is not rediscovered; it is re-applied WITH 1b in one
commit, because alone it is invisible and together they are testable by the
fixture above.

**And item 2 is already named**: `Files.Rider` is an IMPORTED record
(`record f: File; pos: longint; eof: boolean; res: integer; cur: A1 end`), so the
next thing after 1 is how a record's fields lay out when the record's
DESCRIPTION came from another module - which is a question this note does not
answer, and marks as unmeasured.


### 3y. 1b ANATOMY — why the rows aliased, and what the fix must touch

Reading the VM rather than guessing changes 1b's sizing, so it is recorded before
the attempt is made.

**The stride cannot be fixed in the index expression.**  `Op_Load_Idx_I` and
`Op_Store_Idx_I` scale the index by a HARD-CODED eight bytes:

    + System.Storage_Elements.Integer_Address (Idx)
      * System.Storage_Elements.Integer_Address (8);        (vm/obc_vm.adb:2826)

(`..._Idx_B` scales by one byte.)  So a subscript's stride is one slot by
construction, and an element that is a user type - `V4`, four slots - cannot be
reached by it at all.

**And the measured output identifies the defect exactly.**  If the outer
subscript on a user-typed element is DROPPED - `m[i]` yields the base address,
only `[j]` is applied, at stride 8 - then:

    i = 0 writes 0,1,2,3   to bytes 0, 8, 16, 24
    i = 1 writes 10..13    to the SAME bytes
    the print loop reads them back at the same addresses

which prints `10 11 12 13 10 11 12 13` - byte for byte the measured output.  The
model reproduces the observation, so the defect is not "a stride constant": it is

    (i)  the designator must NOT drop a subscript on a user-typed element, and
    (ii) an outer index on such an element needs its offset computed by the
         compiler - `base + idx * Total_Slots (Elem_UT) * 8` - because no opcode
         will do it.

**Why this is landable and safe to attempt.**  It touches the designator path,
which is where the `UTypes (0)` crash and the pointer-field subtlety came from -
but the fixture gates it: `m1` above must print `0 1 2 3 10 11 12 13`, and a wrong
answer fails it and reverts.  Item 1 therefore lands as 1a + 1b + the fixture in
one commit, or not at all, and the current state (refused at the declaration, per
the check at `o2c_compiler.adb:5279`) remains the safe one meanwhile.

Fixture, kept here because the commit that needs it will need it verbatim:

    type V4 = array 4 of integer;  type M2 = array 2 of V4;  var m: M2; i, j: integer;
    (* m[i][j] := i * 10 + j for i in 0..1, j in 0..3; then print each as
       Out.Int (m[i][j], 1) with Out.Char (" ") after it; expect
       0 1 2 3 10 11 12 13 *)


### 3z. ITEM 1: three patches, no effect — so the branch is unverified

Attempted item 1 whole - 1a (recursive size), 1b (the subscript step moves the
base for a user-typed element), 1c (a locally declared array records
`Elem_UT`) - and **reverted all of it**, because the fixture says the work is not
doing what it claims:

    m1 (two-level array)  expected: 0 1 2 3 10 11 12 13
                          measured: 10 11 12 13 10 11 12 13     (unchanged)

with the compiled image the same size (712 bytes) before and after 1b and 1c.
**Unchanged output AND unchanged image size means the emitted code did not
change**, i.e. the branch I patched is not the branch that runs for `m[i][j]`.
That is the finding, and it is worth more than another patch: I was editing a
subscript path on the strength of where it lives in the file, without evidence
that it executes.

1a alone is proven - the progress metric moved to `Files.Rider` with it and moved
back when the whole attempt was reverted - and it is one line, reproduced below.

**The next step is a trace, not a patch.**  The technique that cracked the earlier
cross-module case was instrumenting the two candidate paths and reading which one
fires (`PA in`/`PA out`).  The same applies here: instrument the designator's
subscript step to report base type, element type, `Elem_UT` and which branch is
taken, then run `m1`.  Until that says which code runs, any fix is a guess dressed
as a change - which is exactly what 1b and 1c were.

**State: item 1 is refused, not half-done** (`o2c_compiler.adb:5279`), so the safe
behaviour is unchanged: a nested-array variable is refused loudly rather than
laid out wrongly.  The fixture and 1a are kept in 3x/3y.


### 3aa. THE TRACE SAYS WHERE THE FIX IS *NOT* — the outer subscript never
### reaches the designator's index step

Instrumented the designator chain's subscript step and ran `m1` (with the
scaffolding in place so it compiles at all).  Two hits, and their content is the
whole answer:

    DESIG idx ut= 1 elem=T_INT elem_ut= 0 len= 4
    DESIG idx ut= 1 elem=T_INT elem_ut= 0 len= 4

`ut=1` is `V4` - `array 4 of integer`, `len=4`, a scalar element.  So the branch
fires for the INNER subscript.  There is no hit for `M2` (`len=2`, a user-typed
element).  **The outer subscript is not handled by that code at all.**

Which is exactly why 1b and 1c changed nothing observable: they edited a branch
that never runs for this expression, and unchanged output plus an unchanged image
size (712 bytes) was the tell.  The scaffolding - 1a, the two rules, the
`Elem_UT` recording, 1b, the trace - was reverted, because with the check open it
produces silently wrong answers and that is the one thing this backend exists not
to do.

**So the question is now narrow and factual**: what consumes the outer `[`?

The walker's own subscript step is the only one inside `Parse_Rec_Ptr_Chain`
(traced).  So the outer subscript is consumed BEFORE the walker is entered, or by
a branch that returns early.  That is a one-command question to answer with the
same technique: instrument the ENTRY of the walker (and the array handling that
precedes it) and print, per selector, the kind consumed and the current type.  If
the walker's loop sees only one `[` for `m[i][j]`, the outer one was taken before
it, and the fix belongs there.

**What is NOT in doubt**: 1a is one line and proven by the metric (`Tote` ->
`Files.Rider` with it, back on revert), and the fixture `m1` is the gate.  Both
are recorded in 3x/3y/3z.


### 3ab. WHERE THIS STANDS — and the process fix for the hunt itself

Reverted again: the instrumentation that was meant to name the outer subscript's
site was inserted by LINE NUMBER computed before the scaffold edits and applied
after them, so the markers landed inside multi-line statements and the compiler
rejected the file.  Nothing is left in the tree.

Measured so far, and still valid:

- the designator chain's subscript step fires only for `V4` (`ut=1`,
  `len=4`, scalar element) - the INNER subscript.  The outer one never reaches it;
- so the outer `[` is consumed by one of the six `Parse_Rec_Ptr_Chain` call sites
  (2215, 3506, 4079, 7435, 7991, 8297) or by a branch that returns early;
- 1a is proven by the metric; `m1` is the gate; the item stays refused.

**The process fix this attempt earned is now a repo-wide rule** in
`AGENTS.md` ("Probing the compiler: anchors, negatives, and sizing").

**And the honest read on the hunt**: locating a consumer inside a 11k-line
front end by instrument-and-rebuild is slow in this budget.  It is a
context-heavy, read-only question - which is what the explore subagent is for: it
can read the whole designator/selector path and report the site without spending
the editing budget on guesses.  Proposed rather than done, since it opens a new
exploration path and the guard on this turn said to stop.


### 3ac. DONE — item 1: multi-level arrays (and the site was not where I looked)

A record field that is an ARRAY OF ARRAYS now works, verified by a new fixture
(`tests/bc/nestedarr.ob2`, hand-computed golden, corroborated by both backends),
and the progress metric moved:

    hello.ob2 refuses at  'Tote'  ->  'Files.Rider'

Two halves, as 3x said, but **1b was not the code I had patched three times**:

    1a  `Total_Slots` for an array whose element is a user type is
        `Arr_Len * Total_Slots (Elem_UT)`, not `Arr_Len` - one line.
    1b  the `Elem_UT /= 0` branch inside `Parse_Rec_Ptr_Chain` (line 2073)
        already advanced the type and appended Ada text, and emitted NO ROW
        OFFSET.  The scalar-subscript branch I kept editing is never reached for
        a user-typed element: the `DESIG` trace showed it firing only for `V4`.

The fix lives at that branch and does not touch the wire format: scale the index
by `Total_Slots (Elem_UT) * 8`, add the array's base if it is not already on the
stack, then mark `D.Base_On_Stack` so the next subscript chains from THAT address
instead of re-deriving the array's and dropping the row.

**How it was found, because it is the part worth repeating**: four attempts of
mine failed - three of them harness mistakes (stale line numbers, a regex that ate
real code, anchors that matched more than one site), not wrong hypotheses - and
the site was named in one read-only pass by the **explore subagent**, which could
read the whole designator/selector path without spending the editing budget on
rebuilds.  Two rules this item earned, now cheap to follow:

Both rules from this item are now repo-wide, in `AGENTS.md` under
"Probing the compiler: anchors, negatives, and sizing".

**Item 2 is already visible**: `Files.Rider`, an IMPORTED record
(`record f: File; pos: longint; eof: boolean; res: integer; cur: A1 end`) - so the
next question is how a record lays out when its description came from another
module.


### 3ad. DONE — item 2: a record with a LONGINT field, by value

The checklist called item 2 "an imported record (`Files.Rider`)".  The CAUSE is
more general and was measured, not guessed: `Fields_Allowed`'s list of whole-slot
scalars omitted `T_Long`, so ANY record with a `longint` field was refused -
imported or local - and `Files.Rider` (`f: File; pos: longint; eof: boolean;
res: integer; cur: A1`) was simply the first one the program met.

The measurement that settled it, and the reason it is worth recording:

    hello.ob2     CHK rec=Files.Rider fld='pos' typ=T_LONG scalar=FALSE   <- refused
    e3 (old probe) no CHK line at all, and it PASSED

`e3` declared only a POINTER to such a record.  The field rule runs only for a
variable whose type IS the record, so the old probe never exercised it - the same
blind spot as the `array of char` probes and the offset-0 probes, caught this time
because both cases were measured rather than one (the rule AGENTS.md now carries).

**Fixed** in all three slot lists - a record field, a fixed array's element, and a
standalone array variable's element - since a LONGINT is one whole slot in every
one of those positions.  **Fixture**: `tests/bc/longfield.ob2`, which declares the
record BY VALUE precisely so the rule runs, and cannot pass against a pointer-only
shape.

**Metric**: `hello.ob2` now refuses at

    'Greeting' is not a constant INTEGER expression, so its value cannot be pushed

- i.e. the whole TYPE BLOCK of a 530-line, 18-import program is now accepted, and
the next blocker is a different class: a `CONST` whose value the backend cannot
push.  That is item 3.

All seven suites green, 50 fixtures corroborated by both backends (up from 49),
zero warnings.


### 3ae. ITEM 3 MEASURED — a string constant resolves, but the print path crashes

`Greeting` is a string constant:

    const Greeting = "hello from Oberon-2";     (hello.ob2:39)
    Out.String (Greeting);                      (hello.ob2:178)

The refusal is for any `S_Const` that did not fold to an integer, and the backend
does have a pool (`O2c_BC.Push_Str`) - used for string LITERALS - but `Sym` had no
field for a constant's text, so there was nothing to push.

**Three measurements, and the first one was a mistake worth recording.**

    CONST Greeting lit=FALSE folds=FALSE typ=T_STR text='"hello from Oberon-2"'

A string constant arrives as `typ=T_STR` with its text QUOTED, and **`V.Lit` is
FALSE** for a string - so the first capture, guarded on `V.Lit`, silently never
fired and the refusal stayed.  That is the "guard that cannot be true" mistake,
and the trace is what exposed it (the refusal alone looked like the fix doing
nothing).

**With the guard corrected the const resolves**: the progress metric moved off
`Greeting` entirely.  But the EMISSION crashes:

    raised CONSTRAINT_ERROR : o2c_compiler.adb:9066 index check failed

so `Out.String` on a constant takes a path that indexes something a
pool-pushed value does not satisfy.  `R.CStr := True` - the marker that serves a
whole-array-of-char variable - is evidently not what that path needs for a
constant, and a string LITERAL is the control case that says so: literals work,
and they set whatever is missing.  Reading 9066 against the literal path is the
next step, and it is one comparison, not a hunt.

**Reverted**, because a compiler that raises is worse than one that refuses, and
the item stays refused meanwhile.


### 3af. ITEM 3 — the refusal is gone, the VALUE is wrong; reverted

With the string-constant path in place the refusal disappears and the progress
metric advances again:

    hello.ob2:  'Greeting' ... -> 'Geom.Sqr is not yet supported'

but the fixture, which is what actually decides, prints the WRONG value:

    expected:  hello from Oberon-2
               again hello from Oberon-2
    measured:  0
               0 0

`0` is `Push_Int (Const_Val)` - the integer path, i.e. `Const_Text` was empty, so
the guard `Length (Const_Text) = 0` was true and the pool push never ran.  So the
capture at the declaration still does not fire, even though the 3ae trace showed
`text='"hello from Oberon-2"'` at that very point and the capture is inserted after
the symbol aggregate, not before it.  That is the remaining question and it is a
one-print answer: report `Length (Syms (N_Sym).Const_Text)` immediately after the
capture, and `Is_Open` / `AU` / `N` / `CArg` inside the `Out.String` handler.

Two things this attempt settled, both worth keeping:

- the `Out.String` handler indexed `UTypes (AU)` with `AU = 0` for anything that
  has no user type - an open array, and now a string constant pushed as a pool
  string.  Its own `AU > 0` test two lines below already assumed a guard that was
  missing from the `N` computation, and that asymmetry is what raised
  `CONSTRAINT_ERROR ... index check failed` the moment a constant was accepted;
- an early `return R` in the factor path is NOT equivalent to falling through: the
  shared tail consumes the identifier with `Next` and sets `R.Text`, and skipping
  it produced `expected ')' ... found ident 'Greeting'`.  The push has to be
  suppressed (a guard on the integer push), not short-circuited.

Reverted: a wrong answer is worse than a refusal, which is the whole point of this
backend.  Item 3 stays refused.

Fixture, kept here until it can pass (a registered fixture that cannot compile
breaks `run_bc`, which is why it did not stay in `tests/bc/`):

    module Strconst;
    import Out;
    const Greeting = "hello from Oberon-2";
    const Twice = "again";
    begin
      Out.String(Greeting); Out.Ln;
      Out.String(Twice); Out.Char(" "); Out.String(Greeting); Out.Ln
    end Strconst.

    golden:  hello from Oberon-2
             again hello from Oberon-2


### 3ag. ITEM 3 — three fixes, no change; handed to the subagent

The string-constant path now fires on both sides, proven by traces:

    CAPTURED 'Greeting' len= 21 text='"hello from Oberon-2"'
    USECONST 'Greeting' len= 21        (x3, once per use)

and `Out.String` still prints `0` - while the CONTROL case,
`Out.String ("a literal")`, prints its text.  Three further edits changed nothing:

- `R.CStr := False` (mirroring the literal, measured as typ=T_STR lit=FALSE
  cstr=FALSE against my cstr=TRUE) - no change;
- excluding `S_Const` from the `Find (A.Text) > 0` block in the `Out.String`
  handler, since a constant is not a variable and the literal never enters that
  block at all - no change;
- the `UTypes (AU)` guard for `AU = 0`.

The traces firing is what rules out the "edit silently did nothing" explanation:
these edits ARE in the compiler, and the behaviour is unchanged anyway.  Which
means the emission that produces `0` is somewhere else entirely, and I have been
guessing at code paths in an 11k-line front end for three turns - the identical
situation to item 1, which ended only when the question was handed to a read-only
pass.

So: reverted (a wrong answer must not land), and the question is now precise and
narrow enough to hand over:

    For `Out.String (<string CONST>)` in bytecode mode, where is the `0`
    emitted?  The argument's text IS interned with O2c_BC.Push_Str at the use
    site, and `Out.String ("literal")` works.  Find the code that emits the call
    for each of those two arguments and report the difference.

The fixture and its golden stay in 3af until a fix passes them.


### 3ah. DONE — item 3: string constants

A named string constant now works: `Out.String (Greeting)` prints its text.
Fixture `tests/bc/strconst.ob2` with a hand-computed golden, corroborated by both
backends (51 fixtures corroborated, up from 50).

**The fix is three parts**, and one of them is the whole bug:

1. `Const_Text : Unbounded_String` on the symbol record - a constant is not
   storage, so a string one travels as its text, exactly as a literal does;
2. the capture at the declaration, guarded on `V.Typ = T_Str` and NOT on
   `V.Lit`, which is measured FALSE for a string constant - the guard that could
   not be true;
3. the push at the use site, mirroring a LITERAL's shape: `Push_Str`, `CStr =
   False` (a literal is `cstr=FALSE`; `CStr` means "a whole ARRAY OF CHAR
   VARIABLE"), and - the decisive part - **the shared tail's two jobs, `Next`
   and `return`, done inside the branch**.

**Why that last part is the bug**, from the read-only pass: without it, control
fell through to the shared identifier tail's `Bc_Load`, which minted a ZERO global
and pushed `0` on top of the pool offset.  Native 1 pops one operand, took the 0,
and printed it:

    literal:  [LOAD_CONST <offset>, CALL_NATIVE 1,1]
    constant: [LOAD_CONST <offset>, LOAD_G <slot>, CALL_NATIVE 1,1]   <- extra

Two smaller real bugs fell out on the way: `Out.String` computed
`UTypes (AU).Arr_Len` with `AU = 0` for anything with no user type of its own -
its own `AU > 0` test two lines below already assumed that guard - and an early
`return R` in the factor path is NOT equivalent to falling through, because the
tail consumes the identifier with `Next`; skipping that produced
`expected ')' ... found ident`.

**Method note.** Three edits produced no observable change and the traces proved
they were in the compiler - so the emission was elsewhere and guessing had failed.
Handing the read-only question to the `explore` subagent named it in one pass, for
the second time (item 1 was the first).  That is now the established move for a
stall in this front end, and it is cheaper than a fourth guess.

**Metric**: `hello.ob2` now refuses at `Geom.Sqr is not yet supported` - the type
block and the constant are behind us, and the next item is a USER LIBRARY
procedure call, which is a different class from everything in 3w-3ah.  Its size is
not yet measured, and per the sizing rule it should be measured before it is
worked.


### 3ai. ITEM 4 SIZED — it is 3d, and it is milestone work

Measured before working it (the sizing rule), and the answer changes the plan.

**Why `Geom.Sqr` refuses**: the factor path's default refusal, i.e. its export
carries no bytecode id.  User libraries are compiled in ADA mode by
`Compile_Multi` - they are compiled *before* `Begin_Mode`, exactly as the builtins
were before 3m - so none of their procedures has an id.

**Libraries are NOT blocked by type coverage**: in library shape, `geom.ob2`
compiles to bytecode (856 bytes).  Two earlier attempts at this measurement were
harness artifacts of mine, both worth recording because they are the same two
mistakes already in AGENTS.md:

- compiling a library AS A MAIN MODULE gives M20 export errors
  (`exported VARIABLE 'origin': its RECORD type must be exported`), which is an
  artifact of the shape, not a property of the source;
- `sed 's/\*//g'` to strip export marks also strips MULTIPLICATION operators, so
  `x * x` became `x  x` and the compile died as `'k' is not a declared
  procedure`.  Stripping `*` only when it follows an identifier char, and
  checking `grep -n "x \* x"` afterwards, gives a harness that is actually the
  one intended.

**So item 4 is 3d.**  It needs:

    (a) user libraries compiled in bytecode mode - a Compile_Multi ordering
        change, the same SHAPE as the builtin scoping of 3m, whose compilation
        half is already landed (End_Body, 3m);
    (b) the cross-module VALUE TRANSPORT defect that 3d is parked on - measured
        there as: identical LOCAL shapes work (e1/e2/e3), cross-module returns a
        wrong value (u3) or a malformed image (u4).

That is milestone-sized, not a checklist item, and it is the same defect that
already defeated one attempt.  Recording it here rather than starting it: the
work is worth doing with the tools now available (the export-id threading landed
in 3l, the `explore` subagent has since named two sites in one pass each, and u3
and u4 are small reproductions), but it is a decision about where to spend a
milestone, not a next-step.

Metric unchanged: `hello.ob2` refuses at `Geom.Sqr`.


### 3aj. AUDIT — BLOCK: three widened acceptances, two of them high

An independent review of `git diff 37ebb6e..HEAD -- compiler/ vm/` (the
bytecode-mode and type-coverage work) returns **block**, and the findings are the
class the suites cannot see: new acceptances that can emit a WRONG VALUE where the
old code refused.

BLOCKING

1. o2c_compiler.adb:1105 (high).  `Fields_Allowed` now accepts a record field that
   is `ARRAY OF <user type>` (1315-1321), but `Total_Slots`' FIELD-array arm still
   sizes such a field as `N + Arr_Len` instead of
   `Arr_Len * Total_Slots (Elem_UT)` - the standalone-array arm (1081-1084) does it
   right.  So
       TYPE T = RECORD x, y: INTEGER END;
            P = RECORD a: ARRAY 2 OF T; b: INTEGER END
   gets Total_Slots(P) = 3 instead of 5, and `b` is placed inside `a`'s second row:
   silent aliasing and an undersized run where the old code refused.  This is 3ac's
   fix applied to one arm and not its sibling - the same asymmetry as the `AU > 0`
   case in 3ah, in my own work.

2. o2c_compiler.adb:2093 (high).  The row-stride block added in 3ac re-derives the
   base with NONE of the handling its sibling (2057-2071) was fixed for: no
   `Nested`, no `Is_Ptr` test.  For `p^.field[i]` with a field that is an array of
   records, `Base_On_Stack` is False and `Nested > 0`, so it calls `Global_Array`
   with `Total_Slots (pointer) = 0` (the "needs a non-zero length" refusal the
   2048-2056 comment says was fixed), and where the address IS already on the stack
   it adds the global base ON TOP of the offset address - wrong address plus a
   stray stack value.

3. o2c_compiler.adb:5091 (medium).  The const capture keys on `Typ = T_Str and
   Length (Text) > 0`, but `T_Str` is produced by non-literal paths too (3564,
   4138, 4184, 4868).  The use site (4255-4261) strips quotes only when both ends
   are `"`, otherwise it pushes the raw Ada text; an embedded doubled quote is
   never un-doubled.  The fixture uses the constant only with `Out.String`, so
   nothing covers it.  Review's own caveat: it could not positively trigger this -
   a `CONST t = s` chain appears to refuse because `R.Text` stays empty in bytecode
   mode - so the fix is to capture only on a genuine literal and refuse otherwise.

NON-BLOCKING: the removed char-index block is correctly folded into the array arm,
so nothing newly dead; `Ok_Arr` is properly guarded and a pointer element cannot
reach the stride-0 path; the `Depth > 8` guard is unreachable for arrays but
recursive array types cannot be declared, so no unbounded recursion was added.

REQUIRED, in the audit's words: recurse in the FIELD-array arm of `Total_Slots`;
give the row-stride block the same base derivation as its sibling; capture
`Const_Text` only for a genuine literal and refuse when a `T_Str` constant has none;
and add the fixtures the suites cannot see - an array-of-multi-slot-record field,
`p^.arrOfRecord[i]`, and a non-literal string constant.

So the stretch's tree is green by its tests and NOT trustworthy: three of the seven
changes widened what is accepted, and only the first fixture of each shape exists.
Nothing here is reverted yet; the two high findings are the next work, with their
fixtures, before any milestone.

### 3ak. AUDIT FIXES — attempted, reverted, and the two results identify the shape

Attempted all three of the audit's findings and reverted, because one of them
regressed a landed fixture.

1. `Total_Slots`' field-array arm -> recurse (`N := N + Total_Slots (field, Depth+1)`)
   instead of adding `Arr_Len`.  Compiles; `recarr` prints NOTHING.
   A measurement gap of mine: I discarded the VM's stderr, so "nothing" may be a
   trap.  The next attempt captures both streams - never conclude from a truncated
   failure.

2. The row-stride block derives its base as the scalar sibling does
   (`not Is_Ptr and then not Base_On_Stack -> Load_Addr_G (Global_Array (...) +
   Nested/8)`, else `Nested`).  **`ptrarr` passes** - the intent is right - but
   `nestedarr`, a landed fixture, then MISMATCHES.

3. Capture `Const_Text` only for a genuinely quoted literal (else the constant
   takes the loud refusal).  Untested: nothing exercises it yet.

**What the two results say together** is the useful part.  #2 works where the base
is a POINTER (`ptrarr`, where the sibling block does not run) and breaks where it
is a standalone array (`nestedarr`, where it evidently DOES).  So the sibling block
and mine are both satisfied at once, and the base is pushed twice.  The audit read
the control flow as "the sibling does not run for a user-typed element"; the
`nestedarr` regression says otherwise, at least for a standalone array.

So the fix is not a mirror, it is a SHARING: put the base derivation in the
sibling's own block - where it is already correct and already runs - and leave only
the row SCALING (`Push_Int (row bytes); Mul; Add; Base_On_Stack := True`) in the
user-element branch.  That is one edit instead of a duplicate, and it cannot
double-push by construction.

Fixtures for the next attempt (kept here; NOT in tests/bc/, because a registered
fixture that cannot compile - or that fails like `recarr` did - breaks run_bc, and
the differential globs tests/bc/*.out, so a stray golden breaks that too):

    module Recarr;                       (* record field that is an array of records *)
    import Out;
    type T = record x, y: integer end;
    type A2T = array 2 of T;             (* the type must be NAMED: an inline
                                            `a: array 2 of T` field is refused
                                            with "a field type expected" *)
    type P = record a: A2T; b: integer end;
    var r: P;
    begin
       r.a[0].x := 1; r.a[0].y := 2;
       r.a[1].x := 3; r.a[1].y := 4;
       r.b := 5;
       Out.Int(r.a[0].x, 1); Out.Char(" ");
       Out.Int(r.a[0].y, 1); Out.Char(" ");
       Out.Int(r.a[1].x, 1); Out.Char(" ");
       Out.Int(r.a[1].y, 1); Out.Char(" ");
       Out.Int(r.b, 1); Out.Ln
    end Recarr.                          (* golden: 1 2 3 4 5 *)

    module Ptrarr;                       (* the same, through a pointer *)
    import Out;
    type T = record x, y: integer end;
    type A2T = array 2 of T;
    type P = record a: A2T; b: integer end;
    type PP = pointer to P;
    var p: PP;
    begin
       new(p);
       p^.a[0].x := 6; p^.a[1].y := 7; p^.b := 8;
       Out.Int(p^.a[0].x, 1); Out.Char(" ");
       Out.Int(p^.a[1].y, 1); Out.Char(" ");
       Out.Int(p^.b, 1); Out.Ln
    end Ptrarr.                          (* golden: 6 7 8 *)

Both findings stay OPEN until those two fixtures pass, and `nestedarr` must still
pass with them.

### 3al. AUDIT FIXES, attempt 3 — two mechanisms pinned by measurement

Attempted again and reverted again, but this round produced MEASUREMENTS that pin
the mechanism, which the first two rounds did not.

**Measured 1: removing the base derivation from the user-element branch breaks a
landed fixture.**  With only the scaling left (`Push_Int (row bytes); Mul; Add`),
`nestedarr` fails with `vm: operand-stack depth violation`.  So the SCALAR SIBLING
BLOCK DOES NOT PUSH THE BASE for a user-typed element, and the branch must derive
it itself.  That contradicts 3ak's inference (drawn from `nestedarr` regressing
there) and settles the question in the opposite direction.

**Measured 2: the pointer-field case never reached the branch at all.**  In the
unfixed tree, `p^.a[0].x` refuses with

    bytecode error: an array needs a non-zero length

which is `Global_Array` being handed a POINTER's `Total_Slots` - zero.  That is
exactly what the audit predicted for its finding 2, now observed rather than
argued.

**So the fix is neither of the two attempted shapes**: derive the base in this
branch - as 3ac did, since nothing else will - but derive it the way the sibling
does, with the `Is_Ptr` and `Nested` handling, instead of calling `Global_Array`
on whatever the base type happens to be.  That is the audit's required change
verbatim; what failed was my two approximations of it, and the reason is visible
now: 3ak's version applied the sibling's `+ Nested/8` term to a case where the
sibling had already contributed nothing, and this round removed the derivation
outright on the strength of an inference the depth violation disproves.

**The next step is an instrumented run, not another patch**: print
`D.Base_On_Stack`, `Nested`, whether the base is on the stack at the scaling, and
the base type's `Is_Ptr`/`Total_Slots`, for BOTH `nestedarr`'s `m[i][j]` and
`recarr`'s `p^.a[i]`.  One print answers what three patches have not: which of the
two cases reaches the branch with a base, and which needs one built.

`recarr` and `ptrarr` fixtures remain in 3ak as sources.  Both findings stay OPEN,
and `nestedarr` must pass with them.

### 3am. AUDIT FIX 2 (high) — the pointer-field base, FIXED and corroborated

The instrumented run that 3al asked for gave the incoming state for both shapes,
and that is what settled it:

    standalone array (nestedarr):  base_ptr=FALSE base_slots=8  nothing on the stack
    pointer field    (recarr):     base_ptr=TRUE  base_slots=0  -> Global_Array

For the pointer field the base is a POINTER, so `Global_Array` was being handed
`Total_Slots (pointer) = 0` - the refusal "an array needs a non-zero length" WAS
the bug, exactly as the audit predicted.  The branch now derives the base the way
the scalar sibling does: the whole run at the walked slot when the base is not a
pointer and nothing is on the stack, `Nested` when there is an offset, and
otherwise the address the chain already has.

Landed with `tests/bc/recarr.ob2` (the pointer half), corroborated by BOTH
backends - 52 fixtures now, up from 51 - and every regression guard still passes:
`nestedarr`, `longfield`, `strconst`, `lenopen`, `filesintr`.

Two things about the way this one landed:

- the differential refused the fixture at first with `"p" conflicts with
  declaration at line 20` - Ada being case-insensitive, so `type P` collides with
  `var p`, which is the documented Ada-side limit that recmix/recreal are recorded
  for.  Rather than record another limit, the fixture was RENAMED (`PRec`, `ptr`),
  so it now corroborates instead of documenting a limitation;
- three attempts failed before this one, and what made the third work was a
  measurement rather than a patch: the incoming state of the branch for both
  shapes.  My two earlier attempts were approximations of the audit's required
  shape, and both were wrong in ways only that state could show.

### STILL OPEN - audit finding 1 (high): a record field that is an array of records

By value, the same shape still mis-sizes:

    type T = record x, y: integer end;
    type A2T = array 2 of T;                  (* two slots per element *)
    type PRec = record a: A2T; b: integer end;
    var r: PRec;
    (* r.a[0].x := 1; r.a[0].y := 2; r.a[1].x := 3; r.a[1].y := 4; r.b := 5 *)

    observed:  1 5 3 4 5        expected:  1 2 3 4 5

`b` reads back as `a[0].y`'s value, so `b`'s offset IS `a[0].y`'s: `Total_Slots
(A2T)` is still 2, not `2 * Total_Slots (T)` = 4.  The field-arm edit that makes
it recurse is in the tree, so the next question is measured, not guessed: is that
arm even reached for an array field, or does the offset come from elsewhere?

Its source is kept here and NOT in tests/bc/, because it fails and a failing
fixture breaks run_bc.

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
    tests/differential.sh      both backends vs the golden, three ways — the gate
    tests/ada_host/            the host console shim that lets the Ada side RUN
    tests/run_bc.sh            fixtures in tests/bc/ (.ob2 + .out golden)
    tests/run_m1.sh            the guest build and the Ada-vs-VM diff
    compiler/o2c_compiler.adb  ~11k lines; the FFI call sites are near the end
    compiler/o2c_lexer.ads     the token kinds coverage is measured against
    vm/obc_vm.adb              the VM; natives are in the native dispatch
    vm/vm_platform.ads         the seam spec
    vm/compat-host|aegir/      the two seam bodies
    tools/o2c_bc_host.adb      the host bytecode front end; libs as extra args
    tools/o2c_ada_host.adb     the host Ada-text front end; prints the units
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
