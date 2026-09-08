# o2c — an Oberon-2 compiler for Aegir

Targets the [Aegir](https://…/aegir) operating system. M1 plan:
Oberon-2 (subset, keywords case-insensitive) translated to Ada, built
through aegir's userspace runtime chain from outside the monorepo.

## Layout
- `compiler/` — translator sources (Ada; lexer/parser/emitter M1+)
- `crate/`   — build project for the `o2c.elf` Aegir program
- `samples/` — Oberon-2 sample programs
- `tests/`   — expected-output tests

## Build
AEGIR_ROOT must point at the aegir checkout (default `~/src/aegir`):

    make build     # -> crate/bin/o2c.elf (riscv64, links libaegir_user.a)

Run/deploy `o2c.elf` under Aegir the same way as any userspace ELF
(initrd Test staging or the Sys volume + shell).
