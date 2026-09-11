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

## The o2c ↔ aegir coupling

The two repos are separate, but `o2c.elf` embeds the VM and the Aegir image
ships that one artifact, so the pieces are co-deployed even though the trees
are not. The coupling is real; it just needs writing down.

**What is shared, and by whom:**

- **The VM is `vm/` plus `vm/compat-host/`.** The split is spec-shared /
  body-per-platform: `VM_Platform`'s spec is common, its host body is in
  `compat-host/`, and the Aegir body is in `compat-aegir/`.
- `vm/vm.gpr` builds the host VM from (`.`, `compat-host`, `../compiler`).
- `tools/tools.gpr` builds `o2c_bc_host` from (`.`, `../compiler`, `../vm`,
  `../vm/compat-host`). It needs the VM because `O2c_BC` resolves foreign C
  symbols through `OBC_VM.Native_Id`; the emitter carries that dependency so
  the compiler does not grow a second path to the VM.
- **Host-only targets** — `make vm-host`, `make tools-host` — need no Aegir.
  **`AEGIR_ROOT` is required** for anything touching the Aegir side:
  `make build AEGIR_ROOT=…`, and the guest tests.

**If you add a directory to the VM, add it to both gprs.** A missing source
directory does *not* announce itself as a build failure at the point of use —
it surfaces as a stale tool, which is worse.

**Never suppress a build's output.** `make tools-host >/dev/null 2>&1` with no
exit-status check hid a failing tool build for two turns: `O2c_BC` had gained
the `OBC_VM` dependency, `tools.gpr` did not have `../vm`, the link kept the
old compiler, and every test after that ran a binary without the change in it
and produced confident nonsense.

So: check `$?`, do not redirect a build to `/dev/null`, and before concluding
anything from what a tool printed, confirm the tool contains your change:

    strings tools/bin/o2c_bc_host | grep <something-you-just-added>

That check is cheap and it settles in one command what reasoning about the
source cannot.

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
