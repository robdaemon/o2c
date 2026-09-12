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

Open questions to settle first: how a CHAR array is laid out in the arena; how
`Push_Str` and the const pool relate to a *mutable* string; whether a CHAR
array is one slot plus length or a runtime length elsewhere.

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
