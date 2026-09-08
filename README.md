# o2c — an Oberon-2 compiler for Aegir

Targets the [Aegir] operating system. M1 plan: an Oberon-2 subset
(keywords case-insensitive — the one deliberate deviation from the
Oberon-2 spec) translated to Ada, built through aegir's userspace
runtime chain from outside the monorepo.

## Layout
- `compiler/` — translator sources (Ada; lexer/parser/emitter M1+)
- `crate/`   — build project for the `o2c.elf` Aegir program
- `samples/` — Oberon-2 sample programs
- `tests/`   — expected-output tests

## Build

`AEGIR_ROOT` must point at the aegir checkout. It is **required** and
has no default (no machine-specific fallback paths), so CI and other
machines fail loudly instead of silently building against the wrong
tree:

    make build AEGIR_ROOT=/path/to/aegir     # -> crate/bin/o2c.elf

Run/deploy `o2c.elf` under Aegir the same way as any userspace ELF
(initrd Test staging or the Sys volume + shell).
