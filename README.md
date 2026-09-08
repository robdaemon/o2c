# o2c — an Oberon-2 compiler for Aegir

Targets the [Aegir] operating system. M2 (shipped): an Oberon-2 subset
translated to Ada, built through aegir's userspace runtime chain from
outside the monorepo. o2c itself is written in Ada, built with the
riscv64 chain, and runs **under Aegir** (dogfood).

## Layout
- `compiler/` — translator sources: `o2c_lexer` (tokens), `o2c_compiler`
  (parser + Ada emitter)
- `crate/`   — build project for the `o2c.elf` Aegir program
- `samples/` — Oberon-2 sample programs (`hello.ob2`)
- `tests/`   — expected-output tests (M1 pipeline script lands here)

## M1 status

Supported subset: `module`, `import Out`, `const` and `var`
(INTEGER/BOOLEAN, module-level), nested `procedure`s with value and
`VAR` (by-reference) parameters, full expressions with Oberon
precedence (`+ - * DIV MOD & OR ~ = # < <= > >=`, parens), typed
assignment, control flow (`IF/ELSIF/ELSE`, `WHILE/DO`, `REPEAT/UNTIL`,
`FOR/TO/BY`), **type declarations** (`ARRAY n OF INTEGER|BOOLEAN` and
`RECORD` of scalar fields) with index/field designators, whole-value
copies, procedures and **functions** (`: T` return types with
`RETURN`, usable in expressions), and call statements — `Out.String`,
`Out.Int`, `Out.Ln`, and local-procedure calls. Errors are reported
with line/column.

**Deviation from the Oberon-2 spec (project decision): keywords and
standard type names are case-insensitive** (`module`/`MODULE`,
`integer`/`INTEGER` in type position, `var`/`VAR`, `Begin`… all
accepted). Ordinary identifiers stay case-sensitive.

Not yet in M1: `var`/`type`/records/arrays, procedure parameters,
expressions beyond literals/const refs, arithmetic statements, other
imported modules.

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
