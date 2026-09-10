# OBNC library extensions vs o2c's builtins

OBNC (Karl Landström's Oberon-07 compiler) ships the Oakwood basic
set plus an *extension* library, `obnc-libext`, whose modules are
prefixed `ext`:

| module       | purpose                                        |
|--------------|------------------------------------------------|
| `extArgs`    | command-line arguments (`argv`/`argc`)         |
| `extEnv`     | host environment variables                      |
| `extConvert` | `ARRAY OF CHAR` <-> `INTEGER`/`REAL` conversion |
| `extErr`     | print to the standard error stream              |
| `extTrap`    | install/restore a trap handler                  |

Documented shapes (the `.def` files are not fully indexed, so these
are the reported signatures): `extArgs` exports `count*` and
`Get(n: INTEGER; VAR arg: ARRAY OF CHAR; VAR res: INTEGER)` — and
argument 0 is the *first argument after the program name*; `extEnv`
reads the host environment; `extConvert` converts numbers both ways;
`extErr` writes to stderr; `extTrap` customises the trap handler.

## What o2c ships today

The **Oakwood basic set is complete**: `XYplane`, `Input`, `In`,
`Out`, `Files`, `Strings`, `Math`, `MathL`.  On top of that o2c has
two documented extensions of its own: `Reals` (REAL <-> string:
`Convert`, `ConvertTo`, `Ten`, `Expo`) and `Term` (ANSI terminal
control).

## Mapping

| obnc-libext  | aegir facility                                        | o2c status                                                                 |
|--------------|-------------------------------------------------------|----------------------------------------------------------------------------|
| `extArgs`    | `Aegir_User.CLI.Arg_Count` / `Argument (Index)`       | **shipped (M50)** — `Args`: `count*`, `Get(n; VAR arg; VAR res)`, 1-based  |
| `extEnv`     | `Aegir_User.CLI.Get_Env` / `Set_Env` (`ENV:<Name>`)   | **shipped (M51)** — `Env`: `Get(name; VAR value)`, `Set(name, value)`      |
| `extConvert` | none needed (pure Oberon)                             | **shipped (M52)** — `Convert`: `ToInt`/`ToReal`/`FromInt`/`FromReal`      |
| `extErr`     | fd 2 *is* the console — aegir has no separate stderr  | **shipped (M50)** as console-backed `Err` (documented deviation)           |
| `extTrap`    | traps belong to the kernel; no user handler exists    | **not planned** — documented as not applicable                             |

Two naming/indexing decisions to record with the modules:

- We do **not** use the `ext` prefix: o2c is the only library in the
  picture, so the modules are `Args`, `Env`, `Convert`, `Err`.
- `Args` follows our house style of 1-based arguments (aegir's
  `Argument (1)` is the first token after the program name), whereas
  OBNC's `extArgs.Get (0)` yields the first argument — the difference
  has to be called out in the module comment and the README.

## Proposed milestones

1. ~~**M50 — `Args` + `Err`**~~ **done**: `Args.count*`/`Get` (1-based)
   and the console-backed `Err` (`Write`/`WriteInt`/`WriteReal`/`WriteLn`).
2. ~~**M51 — `Env`**~~ **done**: `Get`/`Set` over `CLI.Get_Env`/`Set_Env`.
3. ~~**M52 — `Convert`**~~ **done**: `ToInt`/`ToReal`/`FromInt`, with
   `FromReal` delegating to `Reals.Convert`.

`extTrap` stays out: with a real kernel there is nothing for a user
trap handler to install.
