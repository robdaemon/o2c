# o2c — an Oberon-2 compiler for Aegir

Targets the [Aegir] operating system. M14 (shipped): an Oberon-2 subset
translated to Ada, built through aegir's userspace runtime chain from
outside the monorepo. o2c itself is written in Ada, built with the
riscv64 chain, and runs **under Aegir** (dogfood).

## Layout
- `compiler/` — translator sources: `o2c_lexer` (tokens), `o2c_compiler`
  (parser + Ada emitter)
- `crate/`   — build project for the `o2c.elf` Aegir program
- `samples/` — Oberon-2 sample programs (`hello.ob2`)
- `tests/`   — expected-output tests (M1 pipeline script lands here)

## M14 status

Supported subset: `module`, `import Out`, `const` and `var`
(INTEGER/BOOLEAN/CHAR, module-level), nested `procedure`s with value and
`VAR` (by-reference) parameters — including **user types (records,
arrays, pointers) as parameters and returns (M11)**, **open array
(`ARRAY OF`) parameters (M12)** and **record extension + type-bound
procedures (M13, static; M14 dynamic dispatch)** — plus **local
`const`/`type`/`var` declarations inside procedures (M10)**, full
expressions with Oberon
precedence (`+ - * DIV MOD & OR ~ = # < <= > >=`, parens), typed
assignment, control flow (`IF/ELSIF/ELSE`, `WHILE/DO`, `REPEAT/UNTIL`,
`FOR/TO/BY`, `CASE` with comma label lists and optional `ELSE`,
`LOOP`/`EXIT`),
type declarations (`ARRAY n OF` scalar element types and `RECORD` of
scalar or pointer-typed fields) with index/field designators,
whole-value copies, procedures and **functions** (`: T` return types
with `RETURN`, usable in expressions), and call statements — `Out.String`,
`Out.Int`, `Out.Ln`, and local-procedure calls.  Errors are reported
with line/column.

**M8 — POINTER types**: `P = POINTER TO Rec` supports the classic
Oberon idiom where the record is declared after the pointer
(`Node = POINTER TO NodeDesc; NodeDesc = RECORD ... next: Node END`).
Pointer variables default to `NIL`; `NEW(p)` allocates the designated
record; `^` derefs (`p^.field`, chained `p^.next^.val`); pointers are
compared with `= NIL` / `# NIL` (and to same-typed pointers) and copied
wholesale.  Ada mapping: `access` types, `p := new T`, `null`, with
`^` dropped (Ada auto-derefs).  The demo builds a small linked list
with `NEW` nodes linked through a `next` field and walks it to a `NIL`
sentinel.  Pointers are module-level only: no `DISPOSE`, no pointer
parameters/return types, and record fields are scalars or pointers
(no nested records/arrays).

**M9 — LOOP/EXIT**: `LOOP` statement sequences run until an `EXIT`
leaves the innermost enclosing `LOOP`.  The Ada mapping emits a
generated label per LOOP (`O2c_Loop_N : loop ... exit O2c_Loop_N;
... end loop O2c_Loop_N;`), so `EXIT` leaves the right loop even when
written inside a nested `WHILE`/`REPEAT`/`FOR`; `EXIT` outside any
`LOOP` is a compile error.  The demo walks a counter to 12 with
`LOOP`/`EXIT`.

**M10 — local declarations**: procedures may declare `const`, `type`
and `var` sections between the header and `BEGIN`.  Locals shadow
parameters and module names (and are dropped at the procedure's
`END`); procedure-local types — including `POINTER TO` a local record
— live only inside the procedure, a local `POINTER TO` must resolve
before the body begins, and a type name may not be redeclared (module
or local).  The demo's `UpTo12` counts to 12 with a local
`const Goal` and local `var k`, and `Dot` builds a record through a
procedure-local pointer type.

**M11 — user types as parameters and returns**: formal parameters may
name module types.  Records and arrays are VAR-only (no structured
value copies, per the Oberon-2 report) and their actual is a whole
variable of exactly that type; `POINTER` types pass by value or `VAR`
(a VAR pointer actual must be a variable, not NIL) and functions may
return a `POINTER` type (record/array returns are rejected).  Actuals
are checked at every call site, and pointer assignments accept
pointer-typed expressions, so `cur := Last(head)` works.  The demo
builds its linked list through `Push(var l: Node; v: integer)`,
`Last(l: Node): Node` and `Sum(l: Node): integer`, and swaps a record
with `SwapPair(var r: Pair)`.

**M12 — open arrays**: a formal `ARRAY OF INTEGER|BOOLEAN|CHAR`
accepts any array of that element type — fixed numeric arrays are
emitted as constrained subtypes of a shared unconstrained Ada base
(`type O2c_Int_Arr is array (Integer range <>) of Integer;` etc., so
Ada's nominal matching works), and `ARRAY OF CHAR` maps straight onto
Ada `String` (char arrays are already `String` subtypes).  The length
of any array is `LEN(a)` (`'Length`); a value open-array parameter is
read-only (element writes are rejected), a `VAR` open array allows
element writes, and a `VAR` open-array actual must be writable (a
value open-array parameter or a string literal is rejected).  The
demo fills and sums integer arrays of any length
(`FillArr(var a: array of integer; …)`, `SumArr(a: array of integer)`)
and measures char arrays with `CLen(s: array of char)`.

**M14 — dynamic dispatch**: a type-bound procedure invoked on a
POINTER receiver (p.M) now dispatches on the runtime tag: the
compiler emits a membership chain (deepest override first, `if
p.all in Circle'Class then Describe_O2c_Circle (Circle (p.all))…`)
so a base pointer widened to hold an extension calls the extension's
method.  Record-variable calls stay statically bound.  Demo: after
`shp := circ` (base pointer widened to a Circle), `shp.Widen(3)` bumps
the circle's radius.

**M13 — extension records, type-bound procedures, WITH/IS (static)**:
`T1 = record (T0) … end` extends a record (all records are emitted as
Ada tagged records); fields are looked up across the extension chain.
`POINTER TO T` is emitted as `access all T'Class`, so a base pointer
can hold an extension and pointer assignments/actuals widen with an
Ada access conversion.  Type-bound procedures are declared as
`procedure (var r: T) Name(…)` and are invoked `r.Name(…)` or
`p.Name(…)`; M13 resolves them **statically** (nearest binding of
the receiver's declared type, overrides included) — dynamic dispatch
is M14.  Receiver Ada parameters are class-wide (`in out T'Class`).
Type tests `p IS T` and `with p: T do … end` guards narrow a POINTER
to a record type (guarded member access emits a view conversion;
methods cannot return values in M13).  The demo widens a `Shape` and
a `Circle` (override), tests `circ IS Circle`, and bumps `circ^.r`
inside a `with circ: Circle` guard.

**Deviation from the Oberon-2 spec (project decision): keywords and
standard type names are case-insensitive** (`module`/`MODULE`,
`integer`/`INTEGER` in type position, `var`/`VAR`, `Begin`… all
accepted; `NEW` is recognized case-insensitively in statement
position). Ordinary identifiers stay case-sensitive.  Sample modules
(`samples/`) spell every reserved word in lowercase (`loop`, `exit`,
`new`, `nil`, `pointer to`, …) so they are easy to type; any case is
accepted.

Not yet in M14: nested modules and other imports (only `Out`),
declaring procedures inside procedures, multi-dimensional arrays,
record-typed fields/nested arrays, method functions
(return values), `SET` and other Oberon-2 types.

## Build

`AEGIR_ROOT` must point at the aegir checkout. It is **required** and
has no default (no machine-specific fallback), so CI fails loudly:

    make build AEGIR_ROOT=/path/to/aegir     # -> crate/bin/o2c.elf

## End-to-end pipeline (verified)

1. Stage `crate/bin/o2c.elf` as `Tests/O2c` via the aegir Makefile's
   `O2C_ROOT` knob and boot a test-mode initrd:
   `make run INITRD_MODE=test O2C_ROOT=../o2c`.
2. o2c compiles the embedded demo module and prints the
   generated Ada with `O2C|` line prefixes between `--- ada begin ---`
   / `--- ada end ---` markers (exact host reconstruction despite
   shared-console chatter).
3. Reconstruct the emitted source on the host, build it with the
   external chain (`gprbuild -P prog.gpr -aP $AEGIR_ROOT/userspace/rts
   -XAEGIR_ROOT=$AEGIR_ROOT`), and stage the resulting ELF the same
   way as any userspace program.
4. Boot it under Aegir and assert the console output.

Verified result: `samples/hello.ob2` compiles, builds, and prints
`hello from Oberon-2` then `42` on the Aegir console.
