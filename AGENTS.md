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

**Never describe the other repo in prose — use its API, or check it.** A
comment in `vm/compat-aegir/` once asserted that the guest has no environment.
It does (Aegir keeps variables as `ENV:<Name>` files, via `CLI.Get_Env`); the
comment was false, nothing could check it, and a reader had to contradict it.
Signature drift is already caught — an incompatible change fails the build —
so the gap is *claims a build cannot see*, and the fix is to make the claim
executable instead of writing it down. Prefer a call over a sentence.

`vm/compat-aegir/aegir_interface.adb` is where that lives: it references every
Aegir API o2c depends on, so drift fails a file whose only job is to fail.
Deliberately **not** a version pin — both repos are under development, and a
pinned revision is either stale on arrival or forces the two into lockstep.
It is an interface check, evaluated against whatever Aegir is now. A unit
nothing calls is never compiled (gprbuild builds only what a main can reach),
so it is reached from `VM_Platform.Init` — an unreached probe passes while
checking nothing, which is how its first version behaved.

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

## Probing the compiler: anchors, negatives, and sizing

- **Instrument by TEXT anchor, never by line number.** A marker inserted at a
  remembered line number lands inside a multi-line statement the moment an
  earlier edit in the same change adds or removes a line, and the compiler then
  rejects the file for reasons that have nothing to do with the hypothesis.
  Match the text, or match the enclosing function's range, and re-read the file
  for the anchor *after* every preceding edit.
- **A negative trace result is a result.** "This branch never fires for that
  input" reduced a failed hunt to one question small enough to hand to the
  `explore` subagent, which named the site in a single read-only pass. Print the
  candidate paths' inputs and read which one fires *before* patching either.
- **Measure two cases, not one.** A real fix - the qualified call path pushed
  every argument twice - was reverted as a non-fix because only one of its two
  symptoms was re-tested: `u3` was unchanged, while `u4` went from a rejected
  image to a running one. When a change is meant to alter behaviour, test every
  case that behaviour covers.
- **When a probe disproves an item's SIZING, not just a hypothesis, stop and
  re-size it in the plan.** Three failures in one stretch were sizing errors
  dressed as bugs: a "wiring" item that needed a cross-module call, a "check"
  that needed a layout change, and a "stride constant" that needed the
  designator to stop dropping a subscript. A wrong size belongs in the plan on
  the day it is found, not after the chase.

- **An edit that silently does nothing looks exactly like a fix that did not
  work.** Four times in one stretch, "the behaviour did not change" turned out to
  mean *the edit never happened*: a `str.replace` that matched nothing (a stale
  line number; an anchor with the wrong indentation), a capture guarded on a
  condition that could not be true (`V.Lit` is false for a string constant, so
  the guard never fired, and the refusal that stayed looked like the fix failing),
  and a tool built before the change. Before concluding anything from what
  something *does*, confirm the artefact contains your change: print it, trace
  it, or `strings` the binary. The existing "confirm the tool contains your
  change" check applies to source and document edits too - the failure mode is
  identical, and a refusal that "stayed the same" is not evidence when the edit
  may not have landed.

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

- **A refusal names its subject.** "call to an unknown procedure", with no name,
  cost rounds of hunting; `'Bracket'` and `('Tote')` each settled their question
  in one run. Anything the bytecode backend refuses should say WHICH construct
  it refused.
- **The gap harness cannot express "compiles, runs, answers wrongly".**
  `tests/bytecode_gaps.sh` records constructs that REFUSE, so a defect of the
  other kind has no machine-checked home. It lives in the notes - or, better,
  becomes a fixture the moment it is fixed.
