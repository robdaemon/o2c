# o2c — agent notes

## Rebuilding generated Ada (o2c's Ada backend only)

This rule matters **only for o2c's Ada backend** — the host/native
harnesses that translate Oberon-2 and then compile the emitted Ada with
GNAT. It does not apply to the Oberon-2 language, the samples, or the
Aegir runtime.

- **Always delete the generated `*.ali` / `*.o` (and the target binary)
  before recompiling emitted Ada.** Stale `.ali` files make GNAT reuse a
  previous compile and either replay old diagnostics or hide new ones;
  a fixture that "passed" can be a false negative from an earlier state.
  When a generated unit changes, so must its artifacts:

      rm -f *.ali *.o <exe> && gnatmake -q -I<stub> -I. main.adb

- **`gnatmake` only *warns* on a source-file/unit-name mismatch** and does
  not actually compile the unit. If you see

      warning: file name does not match unit name, should be "foo.adb"

  the run proved nothing — the file is named e.g. `Foo.adb` for unit
  `Foo`/`foo`. Name the file exactly like the unit (lowercase) before
  drawing any conclusion from a successful compile.

- When testing generated specs, compile a **client** (`with` the unit),
  not just the body: some legality checks on package specifications are
  only enforced when the spec is used from outside.

## Repository conventions

- Builds are serial; never `make -jN`.
- `alr` (reached through aegir's crates when `make build AEGIR_ROOT=...`
  runs) needs a writable temp dir: this sandbox's `/run/user/1000` is
  read-only, so set `XDG_RUNTIME_DIR=/tmp/alrrt TMPDIR=/tmp` (plus
  `XDG_CONFIG_HOME`/`XDG_DATA_HOME`) or `alr build` dies with
  "Could not create temporary file at /run/user/1000/alr-*.tmp".
- Keep the tree warning-free; remove scratch artifacts (`*.ali`, `*.o`)
  from the repo root before committing (they are gitignored).
- Commit after each milestone.
