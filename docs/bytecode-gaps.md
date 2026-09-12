# Bytecode backend: known gaps

Constructs the **Ada** backend accepts and the **bytecode** backend does not.
The executable form of this list is `tests/bytecode_gaps.sh` - one probe per
entry, asserting the current state. **Fixing a gap makes that script fail until
the entry is removed here**, which is what a todo list should do and what a
prose list cannot.

Every entry below was observed failing, not inferred. That rule is written
because it was broken twice in one session: a comment claiming the guest had no
environment, and a "single-import limit" read off one `if` that was in fact
followed by a `loop`. Both were confident and both were false. Listing a gap
requires a probe.

## Priority, by what is load-bearing

### 1. ARRAY OF CHAR (and of BOOLEAN, of REAL)

The check is `Ok_Arr := Arr_Len > 0 and then Elem = T_Int` - **only INTEGER
arrays**. Nothing in `docs/` justifies it, so it is unfinished work rather than
a decision.

String *literals* work (`Out.String ("...")` compiles and runs - the const pool
carries them). What cannot be done is **build, pass, store, or return a
string**: no `ARRAY OF CHAR` variable at all.

This is the one that gates the others. Every one of the ten FFI helpers below
takes or returns an `ARRAY OF CHAR`, so none of them can be exercised - and
none of the fixes for them can be demonstrated - until this lands. It is the
difference between "bytecode mode runs the demo programs" and "bytecode mode
can replace the Ada backend".

**Layout — settled, and the work sized.** `Push_Str` stores `Text & NUL` in the
const pool's string area: **NUL-terminated, one byte per char**. The guest's
`Console.Put` takes an Ada `String`, which is the same thing. So a packed CHAR
array is the only layout that can be handed to the existing natives unchanged,
and the alternatives would have needed a converting native that the guest has
no reason to understand. **One byte per char, NUL-terminated** — decided.

That makes the pieces concrete, and three of them were built and reverted
because the fourth is wrong:

- `Total_Slots` must return `(N + 2) / 8` slots for a CHAR array, not `N` —
  bytes rounded up, with the terminator. Built, compiles.
- The index ops are `Bas + Idx * 8`; the byte versions are the same with scale
  1, and the load must **zero**-extend, since a CHAR is unsigned and sign
  extension would corrupt anything above 127. Built, compiles.
- There are **five** index emission sites, not three: three loads, two stores.
  One is the *open array* path, where `D` (the designator) is not in scope and
  the element type comes from `Syms (Id).Typ` instead. Worth knowing before
  editing them.
- **The blocker:** indexed CHAR access reads the wrong byte. `s[2] := c;
  Out.Char (s[2])` prints byte value 2 — the *index*, not the stored character.
  So the base address or the operand order in the emitted sequence is wrong.
  That is the thing to debug, and it is why the whole change was reverted:
  a silent wrong value is worse than the block it replaced.

**The canonical sequence, decoded** (`a[1] := i` for an INTEGER array, via
`/tmp/probe3.py`-style dumping of the CODE section). Opcode bytes:
`Load_G = 0x12`, `Load_Const = 0x14`, `Load_Idx_I = 0x1D`, `Store_Idx_I = 0x20`,
`CALL_NATIVE = 0xC3`, `HALT = 0x01`. The shape is:

```
... 12 00 00 00 00   LOAD_G <slot>      <- the array base, immediately before
    20               STORE_IDX_I
... 1d               LOAD_IDX_I         (the base pushed earlier)
```

So the base goes on the stack just before the index op, and the byte ops sit
exactly where the integer ones do. **That rules out the operand order and the
emission sites**: a byte op substituted 1:1 has the same stack discipline.

**The cause, found by disassembling the CHAR case rather than the integer one.**
`s[2] := c` emits only the operands - `LOAD_G 0`, `LOAD_CONST 2` - and *no index
op at all*. So the index is left on the stack, and `Out.Char` prints it. That
matches the symptom exactly, and it explains why the ops looked innocent: they
are never emitted.

The site is `Parse_Rec_Ptr_Chain`:

```ada
if VK = V_Arr and then UTypes (UT).Elem = T_Char then
   D.K := D_Str;
   return D;
end if;
```

A CHAR array designator short-circuits to `D_Str` - "the whole array as a
string" - **unconditionally**, overriding any index the selector loop has just
parsed. `s[2]` is therefore classified as the whole string rather than as an
indexed element, and the path that runs emits the base and the index and no op.
Pre-existing: the branch has always been there, and CHAR arrays being refused
is what kept it unreachable.

The fix is at that branch - return `D_Str` only when no index was selected -
and it is the *first* thing to do, before any of the opcode work, because the
index op was never the problem.

Earlier hypotheses that measurement disproved, recorded so they are not retried:
the operand order, the emission sites, "a CHAR literal assignment stores a pool
offset" (CHAR assignment is correct: `c := "a"` prints `a`, `ord (c)` is 97),
and "the base address or the footprint". None survived a probe.

What is left, and where to look next: the **base address** and the
**footprint**. `Total_Slots` was changed to return `(N+2)/8` slots for a packed
CHAR array, and `Global_Array` is handed that number — but `Load_Addr_G` yields
a slot address, and the second slot of a 2-slot packed array is then addressed
as byte offset 8, past the 9 bytes it actually holds. The next probe is to dump
what `Load_Addr_G` pushes for a packed array and what the indexed op computes
from it, rather than assuming either.

### 2. CONST in an expression

`const N = 3; ... k := N` fails with `'N' is not a module variable`. Named
constants are unusable in bytecode mode, so every program must inline its
numbers. Small, self-contained, and it affects ordinary code rather than a
library edge - arguably the first thing to fix on effort-to-value.

### 3. SET variables

`type S = set of 0 .. 7; var s: S` is refused with "expected ARRAY, RECORD or
POINTER in type S". Sets exist as operations (there are `Set_*` opcodes and a
`set.ob2` fixture); what is missing is a SET **variable**.

### 4. LONGINT assignment

Declaration is accepted; **assignment** is not ("only INTEGER/CHAR/BOOLEAN
assignments"). Found by this list's own first run, which contradicted the claim
that had just been written beside it.

### 4b. `s := <string literal>` does not copy

The statement compiles and copies **nothing** - the array keeps its zeros.  It
is `Append_Body` only; the branch at the string-literal-into-ARRAY-OF-CHAR site
has no bytecode path.

An attempt is recorded rather than landed, because it does not work and the
failure is one step further on: `Op_Copy_Str` (copy a pool string into a packed
array, pop the const offset and the destination, NUL-terminate) built and
emitted correctly - the dump shows `LOAD_ADDR_G`, `LOAD_CONST`, `0xED` in the
right order and the verifier accepts the depth - but the program then fails at
the *next* statement, `Out.Char (s[0])`, with "value out of range".  So the copy
runs and writes to the wrong place.

The next probe is therefore to check the destination address rather than the
op: `0x16` is `LOAD_ADDR_G` and `0x12` is `LOAD_G`, and the integer-array store
sequence uses `0x12` where this uses `0x16` - worth confirming which one the
array base is supposed to be before assuming either.

Also found on the way: `Out.String (<CHAR array variable>)` does not merely emit
nothing, it ends the run - no output at all, not even the following statement.

### 4c. `Out.String (<CHAR array variable>)` ends the run

It compiles and then dies: `operand-stack depth violation`, exit 1.  The native
that prints a string takes an *offset into the const payload*, and a CHAR array
variable is not in the const payload - so it cannot be handed over directly.

**No new native can be added.**  `Max_Natives` is 5 and ids 0-4 are all taken
(`Int`, `String`, `Ln`, `Real`, `LongReal`); foreign ids are computed as
`Max_Natives + I - 1`, so a sixth builtin renumbers every foreign function
starting with `labs` - which the append-only rule forbids, and which would
break silently.  The comment beside that table claims the two tables "cannot
collide and neither needs renumbering to grow"; bumping `Max_Natives` does
renumber them.

The route that needs nothing new: print the array a character at a time through
**`Out.Char`'s native (id 4)**, which takes the character code directly.  That
was built - a loop with a temporary index and value local, bounded by the array
length and stopping at the terminator - and it **compiles and emits cleanly**,
but the verifier rejects it with a depth violation while the *emitter's* own
depth tracker accepts it.  **The two disagree**, and that disagreement is the
thing to understand next, not the loop.

A hypothesis was recorded here and then **disproved by reading the tracker**:
that the emitter tracked depth per statement while the verifier tracked it
globally, so a push by the factor would be visible to one and not the other.
It does not - `Pushed`/`Popped` maintain a single `Depth` counter reset only by
`Reset`, once per program, which is the same scope the verifier uses.

What the two runs actually say, which is more useful:

- **with** a `Discard` for the address the factor is assumed to push, the
  *emitter* raises `operand-stack underflow` - so the factor did **not** push
  one, and the discard was wrong;
- **without** it, everything compiles and the *verifier* rejects the result.

So the two disagree about the loop itself, not about a leftover from the factor.
Counting the emitted sequence by hand gives net zero per iteration with matching
depths at both exits, which means the count is not the way to find this either.

Next: dump the loop's bytes and the verifier's per-offset depth, and compare
them position by position.  That is the move that settled the two previous
CHAR bugs after reasoning had failed on both.

### 4d. String comparison emits no comparison

`s = t`, `s # t` and `s < t` between two `ARRAY OF CHAR` variables all compile
and then die on `operand-stack depth violation`.  Dumping the code shows why:
`f := s = t` emits the two `COPY_STR`s and then `STORE_G 4` with **no
comparison between them**, so the store pops a value nothing pushed.

The site is the relational-operator block in the expression parser, where
`Tok_Equal`/`Tok_NE`/`Tok_LT`/`Tok_LE`/`Tok_GT`/`Tok_GE` are turned into an Ada
operator string.  That path builds Ada text and has no bytecode branch for two
string operands - the same shape as the string assignment and the FFI helpers.

`0xEE` is the next free opcode: `0xE5`-`0xED` are taken and the `0xF0` escape
range is reserved.  The natural instruction is a three-way compare that pops
two addresses and pushes -1, 0 or 1, from which `Eq`/`Ne`/`Lt`/`Le`/`Gt`/`Ge`
against zero give all six operators - one op rather than six.

**Built to that design, and it reaches a second problem.**  `Op_Str_Cmp`
(0xEE), its interpreter and verify clause, the enum entry and the emission in
the string case of the relational block all work - the dump shows `ee` between
the two operands and the `Eq` against zero after it.  But it still fails:
**the operands are not on the stack when it runs.**

In `f := s = t` the two `COPY_STR`s for the assignments consume the addresses
the factor pushed, and nothing re-pushes them for the comparison - so a CHAR
array designator pushes an address in `Out.String`'s context (where that code
works) and nothing in a comparison context.  The `D_Str` early return in the
chain is where the difference lives.

That is the next thing to find, and it is one question: **does the factor push
an address for a bare CHAR-array name, and if so on which paths?**  Dump
`s := "hi"; f := s = t` and watch the depth either side of the `ee`.  The
compare op itself is written and correct.

### 5. Inline (anonymous) array types

`var v: array 4 of integer` fails with "a type name expected". An array type
must be named. Ergonomic rather than load-bearing.

## The ten FFI helpers with no bytecode emission

`Env.EnvGet`, `Env.EnvSet`, `Convert.ConvToInt`, `Convert.ConvFromInt`,
`Arg.ArgGet`, `XYplane.PlaneClear`, `XYplane.PlaneOpen`, `In.InReset`,
`Files.FDel`, `Files.FRename` - each appends to the Ada body and makes **no
`O2c_BC` call at all**. Their branches carry no `Bytecode_Mode` guard, so in
bytecode mode they compile, run, and quietly do nothing.

All ten now refuse instead of emitting nothing: `Env` in `9078a84`, the other
nine next commit. That removes a silent no-op from the language's own library,
which is worth doing on its own. **It does not make any of them work, and none
of the refusals could be demonstrated reachable** - see the correction below.

**Correction to the reasoning in `9078a84`.** That commit expected the refusals
to become reachable "the moment the ARRAY OF CHAR restriction is lifted". CHAR
arrays work now, and the branches are still unreachable for a second and
independent reason: `Out` is the only builtin module (`o2c_compiler.adb:469`), so
every other module name - `Files`, `Convert`, `Args`, `XYplane`, `In`, `Env` -
takes the M19 library path, which requires a compiled module *source* that
exports the member. Probing with `import Files; ... Files.FDel(n);` now fails
earlier, at `'Files.FDel' is not exported by module Files`, not at the FFI branch.

**CORRECTED, and the harness already exists.** The built-in module sources are
embedded in the compiler as `Oak_Convert_Src`, `Oak_Files_Src`, `Oak_Env_Src`,
`Oak_Args_Src`, `Oak_XYplane_Src`, `Oak_In_Src` and the rest
(`o2c_compiler.adb:10178` onward). They are compiled by `Compile_Multi` on every
call. Nothing named `Files.ob2` or `Convert.ob2` exists on disk because the
sources live in the compiler, not in a file - "no file found" was read as "no
source exists", which led to a generated duplicate with wrong public names
(reverted: `53fc125`). There is nothing to write, and nothing to generate.

**The real blocker is one flag set too late.** `Compile_Multi` compiles every
builtin and every user library, and only THEN calls `O2c_BC.Begin_Mode`
(`o2c_compiler.adb:11273`). So all of them are parsed in Ada mode,
`Bytecode_Mode` is false throughout, and their FFI branches take the Ada path -
appending to a body that `Emits` then discards in bytecode mode. That is why the
refusals cannot fire and why the suites pass.

**But simply moving `Begin_Mode` earlier is NOT the answer.** It would put every
builtin into bytecode mode, not just the FFI ones - Strings, Texts, Math, MathL,
In, Input, Term, Reals. Those are not small: Math and Reals do REAL arithmetic,
and the bytecode backend still refuses mixed INTEGER/REAL and LONGINT operations
in several places. Compiling them under `Bytecode_Mode` would make the bytecode
pass fail on its own builtins. The suites would catch it, but the change is
wrong in principle as well as in effect.

**The intent is already stated in the code.** `Emits` carries the comment "the
VM calls the Oakwood surface as NATIVES, so the Ada units are irrelevant there".
So the designed path is that an FFI module's surface is exposed to bytecode as
*natives* and its dialect source is used only for the Ada backend - not that the
dialect source is compiled to bytecode.

That means the work is: when the main source (or another bytecode unit) calls an
FFI builtin's exported procedure, emit `Native_Call` for it, and implement the
native in the VM. The `Oak_*_Src` bodies stay as they are, driving the Ada
backend exactly as now. What has to be replaced is the M19 import path's
treatment of these calls, plus the ten FFI *statement* branches, which currently
build Ada text and have no bytecode counterpart.

**And the path is reachable after all - with the real public names.** Probing
with the names the embedded sources actually export changes the picture:

    Convert.ToInt (s, x, r)    compiles, but the image is MALFORMED:
                               the VM refuses it with "cannot read image"
    Convert.FromInt (x, s)     same
    Files.FDel / Env.EnvGet    "is not exported" - those are the wrong names

**Corrected again, and this time the failure is a parse error, not a bad image.**
The image was never malformed: the compiler refused the source, wrote no file,
and the VM's "cannot read image" was simply a missing file. That misreading came
from running the compiler with its output discarded and believing the downstream
symptom - the one thing the project's own rule forbids.

Measured, by isolating one variable at a time:

    import Convert;                       compiles (168 bytes)
    import Convert; import Out;           FAILS
    import Out;  then import Convert;     (same failure)
    import Out; alone                     compiles
    a plain program through the same tool boots and prints

So the bug is not `Convert`, and not `Out`: it is importing a builtin FFI module
**together with `Out`**. The error is `expected
CONST/VAR/TYPE/PROCEDURE/BEGIN/END`, and `Out` is the one module with special
handling (`Imported_Mod` returns False for it by construction), so the two import
kinds are not composing.

**And there is no import bug either.** `import Convert, Out;` - one clause,
comma-separated - compiles, runs and prints. The dialect takes ONE import
clause, exactly as `samples/hello.ob2` shows; my probes wrote two separate
`import` statements, which it does not accept. The clause parser is an `if`, not
a `while` (`o2c_compiler.adb:9100`), which is what made a second clause fail
with "expected CONST/VAR/TYPE/PROCEDURE/BEGIN/END". My syntax was wrong, not
the compiler's - for the fourth time in this stretch.

**Convert.ToInt NOW WORKS**, and it is the template for the other nine.

    module FFI;  import Convert, Out;
    s := "42";  Convert.ToInt (s, x, r);  Out.Int (x, 0)      -- prints 42

The FFI surface takes ADDRESSES, not values. These procedures are written in
terms of out parameters - ToInt's two `var` formals - so the call site pushes
where the results go (`Load_Addr_G`) and the native writes through. That shape
is shared by all ten helpers, so it was worth fixing once here.

**The one thing that was not obvious: position decides the parameter role, not
type.** An `ARRAY OF CHAR` actual parses with `Typ = T_INT` - it arrives through
an open-array formal - so testing `Typ = T_Str` for the string argument silently
fails and falls through to the refusal. The parameter *position* is the only
reliable discriminator for this surface. That was found by putting the actual
values in the error message and letting the compiler report them, after two
guesses at the condition were wrong.

`tests/bc/ffi.ob2` holds the golden, and `tests/bytecode_gaps.sh` asserts the
converted value rather than merely that it compiles.

**A thin wrapper is necessary but NOT sufficient - the primitive behind it
decides the cost.** `In.Open`/`String`/`Name` are one call each, but the
primitives they call are a real tokenizer: `O2c_In_Name` calls `O2c_In_Token`,
which calls `O2c_In_Skip` and `O2c_In_Load`, over a line buffer with a
position. That is the Ada backend's shadow implementation of input, and the VM
would have to grow the same state. Same shape as the plane (below) and as the
`Files` readers.

So the exported bodies say which procedures are reachable; they do not say how
much work each is. The cost is in the primitive, and the Ada backend's helper
for that primitive is the spec.

**`XYplane` needs no platform seam.** The Ada backend does not touch hardware:
it keeps a shadow plane in the program (`Plane`, `Plane_W`, `Plane_H`), with
`O2c_Plane_Open` sizing and zeroing it, `O2c_Plane_Clear` zeroing it,
`O2c_Plane_Dot` setting a cell and `O2c_Plane_IsDot` reading one. The VM should
hold the same state itself - it is not a per-platform question, and adding a
seam for it would be inventing a difference that does not exist.

And `XYplane` has an observability constraint worth stating: `Dot` has no
observable effect without `IsDot`, and `IsDot` is a FUNCTION, so it goes through
the expression path rather than the statement path every helper so far has used.
The minimal verifiable `XYplane` unit is therefore Open + Dot + IsDot together,
spanning both paths.

**The FFI surface, measured from the exported procedure BODIES.** This is the
only method that has held up; three earlier attempts here went wrong, twice by
searching for a declaration instead of a use and once by requiring `Name (` when
the primitive takes no arguments (`PlaneClear`, `InOpen`).

    Env.Get  (name, var value)      -> EnvGet (name, value)        thin
    Env.Set  (name, value)          -> EnvSet (name, value)        thin
    Args.Get (n, var arg, var res)  -> ArgGet (n, arg, res)        thin
    XYplane.Clear                   -> PlaneClear                  thin
    XYplane.Dot (x, y, mode)        -> PlaneDot (x, y, mode)       thin
    XYplane.IsDot (x, y): boolean   -> PlaneIsDot (x, y)           thin, RETURNS
    XYplane.Key: char               -> PlaneKey                    thin, RETURNS
    XYplane.Open                    -> X:=0;Y:=0;W:=640;H:=400;    HAS LOGIC
                                       PlaneOpen (W, H)
    In.Open / String / Name         -> one primitive each          thin

    Files.Delete (name)             -> FDel (name)                 thin    DONE
    Files.Rename (from, dst)        -> FRename (from, dst)         thin    DONE
    Files.Old / Read / Write / Close / New                         HAS LOGIC

So the picture is the opposite of what `Files` alone suggested. **Everything
outside `Files` is a thin wrapper**, and only two procedures have real logic -
`XYplane.Open`, which sets four module globals before calling its primitive, and
the `Files` readers, which allocate and copy. A thin wrapper is inline-able at
its call site; the two with logic are not.

Correction to the earlier entry, which said `PlaneClear` and `InOpen` were never
called: they are, from `XYplane.Clear` and `In.Open`. The regex that missed them
required a `(` and they take no arguments.

**Each primitive, and the exported procedure that reaches it.** Read from the
`Oak_Files_Src` bodies rather than from the names, which is the only way that
has worked here:

    FStat  (name)              -> value        exported as Old
    FRead  (name, pos, cur)    -> value        exported as Read
    FWrite (name, pos, cur)    -> value        exported as Write, WriteString
    FClose (name)              -> value        exported as Close
    FRename(from, dst)         -> statement    exported as Rename
    FDel   (name)              -> statement    exported as Delete

So `Files.FDel` is not exported under that name, but `Files.Delete` **is** the
exported procedure for it - calling the primitive name gives "not exported by
module Files", which is what made it look absent. An earlier note in this file
called `Files.Delete` a string delete; it is the file delete, and the body says
so (`Delete (name) ... FDel (name)`).

Two shapes, and both are already exercised: `Convert.ToInt` is the statement
form taking addresses, `Convert.FromInt` the mixed value/address form. The
four value-returning ones here (`FStat`, `FRead`, `FWrite`, `FClose`) are a
third: a native that returns a result, which is what `labs` already does.

**Which of these can be inlined as a native, and which cannot.** Read from the
bodies: a procedure whose body is *exactly one primitive call* is inline-able at
its call site, and nothing else is.

    Delete (name)        -> FDel (name)                      inline-able  DONE
    Rename (from, dst)   -> FRename (from, dst)              inline-able  DONE

    Old (name)           -> new(f); f^.size := FStat(name);  NOT inline-able
                            <copy up to 64 name chars>; return f
    Read / Write / Close / New                               NOT inline-able

`Old` is the clearest case: it allocates, calls the primitive, copies the name
into a fixed 64-byte field and returns the record. That is real logic, not a
primitive, so inlining it would mean reimplementing the module in the compiler.
The rest of `Files` is the same shape.

So the cherry-pick approach reaches exactly two procedures in this module.
Beyond them, `Files` needs its own source compiled to bytecode - the design
question deferred earlier, not a fourth call-site emission.

**What has to be wired is the CALL SITE via M19, not the FFI statement branch.**
The branches fire while compiling the module itself, and the module is compiled
in Ada mode before `Begin_Mode` - so they stay unreachable, and the route user
code takes is the imported-procedure path, exactly as for Convert.

This is the first demonstration of the silent no-op rather than an argument that
it must exist, and it needs no change to `Begin_Mode`, no new sources and no new
harness. It is upstream of the fork below only in the sense that it is the thing
to fix.

My earlier names were guesses (`ConvToInt`); the embedded source's own are
`ToInt`/`ToReal`/`FromInt`/`FromReal`, and the FFI branches match the *primitive*
written in the body rather than the exported name.

**This is a design choice, not a mechanical edit, and it should be made
deliberately**: natives for the whole Oakwood surface (matching the comment, and
what `labs` already does) versus compiling some builtins to bytecode. The
existing `labs` - a foreign function reached by `Max_Natives + I - 1` - is the
precedent for the first.

## Not gaps

Recorded so they are not mistaken for omissions:

- **Record extensions, records with CHAR or REAL fields, pointers** - probed
  and working. The error message for non-INTEGER arrays names all three, which
  is how they came to be listed as broken; the message overstates.
- **Parameterless procedure calls** - fixed in `4c1e654`; kept as a probe so a
  regression shows up here.
- **Procedure types with parameters** - refused *deliberately* (see M62).
