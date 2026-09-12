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

### 5. Inline (anonymous) array types

`var v: array 4 of integer` fails with "a type name expected". An array type
must be named. Ergonomic rather than load-bearing.

## The ten FFI helpers with no bytecode emission

`Env.EnvGet`, `Env.EnvSet`, `Convert.ConvToInt`, `Convert.ConvFromInt`,
`Arg.ArgGet`, `XYplane.PlaneClear`, `XYplane.PlaneOpen`, `In.InReset`,
`Files.FDel`, `Files.FRename` - each appends to the Ada body and makes **no
`O2c_BC` call at all**. Their branches carry no `Bytecode_Mode` guard, so in
bytecode mode they compile, run, and quietly do nothing.

`Env` now refuses instead of emitting nothing (`9078a84`). The rest have not
been changed. **None of them can be tested yet**, because all of them take
`ARRAY OF CHAR` and that is gap 1 - so this section is currently reasoned and
unverified, and says so.

## Not gaps

Recorded so they are not mistaken for omissions:

- **Record extensions, records with CHAR or REAL fields, pointers** - probed
  and working. The error message for non-INTEGER arrays names all three, which
  is how they came to be listed as broken; the message overstates.
- **Parameterless procedure calls** - fixed in `4c1e654`; kept as a probe so a
  regression shows up here.
- **Procedure types with parameters** - refused *deliberately* (see M62).
