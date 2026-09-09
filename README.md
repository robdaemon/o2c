# o2c — an Oberon-2 compiler for Aegir

Targets the [Aegir] operating system. M10 (shipped): an Oberon-2 subset
translated to Ada, built through aegir's userspace runtime chain from
outside the monorepo. o2c itself is written in Ada, built with the
riscv64 chain, and runs **under Aegir** (dogfood).

## Layout
- `compiler/` — translator sources: `o2c_lexer` (tokens), `o2c_compiler`
  (parser + Ada emitter)
- `crate/`   — build project for the `o2c.elf` Aegir program
- `samples/` — Oberon-2 sample programs (`hello.ob2`)
- `tests/`   — expected-output tests (M1 pipeline script lands here)

## M10 status

Supported subset: `module`, `import Out`, `const` and `var`
(INTEGER/BOOLEAN/CHAR, module-level), nested `procedure`s with value and
`VAR` (by-reference) parameters and **local `const`/`type`/`var`
declarations inside procedures** (M10), full expressions with Oberon
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

**Deviation from the Oberon-2 spec (project decision): keywords and
standard type names are case-insensitive** (`module`/`MODULE`,
`integer`/`INTEGER` in type position, `var`/`VAR`, `Begin`… all
accepted; `NEW` is recognized case-insensitively in statement
position). Ordinary identifiers stay case-sensitive.  Sample modules
(`samples/`) spell every reserved word in lowercase (`loop`, `exit`,
`new`, `nil`, `pointer to`, …) so they are easy to type; any case is
accepted.

Not yet in M10: nested modules and other imports (only `Out`),
declaring procedures inside procedures, record-typed fields/nested
arrays, `WITH`/type extension/type-bound procedures, `SET`
and other Oberon-2 types.

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
