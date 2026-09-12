# RESUME — starting point for the next session

Written at the end of a long session on the bytecode backend's FFI surface,
then corrected and extended by the three sessions that followed it - the unary
operators, construct coverage, and descending FOR.
Read this first; the details live in `docs/bytecode-gaps.md`.

    HEAD            find it with:  git log --oneline -1
    commits         303
    fixtures        72 in tests/bc/
    foreign natives 21 in vm/obc_vm.adb
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
