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

## Read the thing that actually contains the answer

Rounds get lost to checking something *adjacent* to the answer and treating its
silence or noise as the answer. Concretely, in this repo:

- **The guest console is `/tmp/run_m1_boot.log`** (`$WORK/boot.log`, copied on
  exit when non-empty) — *not* `run_m1.sh`'s own stdout. The harness log holds
  only its progress lines (7 of them on a pass), so grepping it for guest
  output finds nothing and proves nothing. That mistake produced a confident
  and wrong claim that the VM never ran in the guest.
- **Never `tail -1` a VM failure.** The informative line ("internal error in
  phase 3: STORAGE_ERROR …") prints *before* the mapped status ("malformed
  code"). Truncating to the last line hid the real error for three rounds and
  sent a hunt after the loader. Read the whole failure.
- **Compare goldens with `cmp`/`diff` against the file**, never by eye through
  `tr`/`head`. A `tr '\n' ' '` squashed a passing multi-line golden into one
  line and reported it as a failure.
- **When a checker and the artefact disagree, suspect the checker first**, and
  verify it against a case whose answer is known. A misaligned dump reader —
  assuming a fixed table offset instead of reading it from the header — sent
  three rounds after a bug that did not exist.
- **Prefer a narrow instrumented run over reasoning about output.** A single
  probe printing the worklist state (`marked 2730 up to next 8190`) named a
  mark/sweep convention mismatch in one run, after several rounds of deduction
  had not.

## Repository conventions

- Builds are serial; never `make -jN`.
- Changing the aegir runtime (`userspace/rts`, `userspace/gnat-rts`)
  needs a `make build`; the Makefile drops the ELF first when a
  runtime archive is newer, because those archives are linked with
  `-L/-l` and gprbuild would otherwise skip the relink.
- `alr` (reached through aegir's crates when `make build AEGIR_ROOT=...`
  runs) needs a writable temp dir: this sandbox's `/run/user/1000` is
  read-only, so set `XDG_RUNTIME_DIR=/tmp/alrrt TMPDIR=/tmp` (plus
  `XDG_CONFIG_HOME`/`XDG_DATA_HOME`) or `alr build` dies with
  "Could not create temporary file at /run/user/1000/alr-*.tmp".
- Keep the tree warning-free; remove scratch artifacts (`*.ali`, `*.o`)
  from the repo root before committing (they are gitignored).
- Commit after each milestone.
