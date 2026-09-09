# o2c — an Oberon-2 compiler for Aegir

Targets the [Aegir] operating system. M36 (shipped): an Oberon-2 subset
translated to Ada, built through aegir's userspace runtime chain from
outside the monorepo. o2c itself is written in Ada, built with the
riscv64 chain, and runs **under Aegir** (dogfood).

## Layout
- `compiler/` — translator sources: `o2c_lexer` (tokens), `o2c_compiler`
  (parser + Ada emitter)
- `crate/`   — build project for the `o2c.elf` Aegir program
- `samples/` — Oberon-2 sample programs (`hello.ob2`)
- `tests/`   — expected-output tests (M1 pipeline script lands here)

## M36 status

Supported subset: `module`, `import Out`, `const` and `var`
(INTEGER/BOOLEAN/CHAR, module-level), nested `procedure`s with value and
`VAR` (by-reference) parameters — including **user types (records,
arrays, pointers) as parameters and returns (M11)**, **open array
(`ARRAY OF`) parameters (M12)** and **record extension + type-bound
procedures (M13 static, M14 dynamic, M15 method
functions)**, and **record-typed fields + nested arrays (M16)**, and **SET and LONGINT scalar types (M17)**, and **REAL (M18)** — plus **local
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

**M36 — extension and array aggregates**: record aggregates now work
on single-level extension types: the compiler emits an Ada extension
aggregate over a qualified parent aggregate (`{a = 5, c = 7}` on a
record extending B becomes `(B'(a => 5, b => 0) with c => 7)`),
including inherited-field names where exported.  Fixed numeric/bool
ARRAY variables accept positional `{e1, e2, ...}` literals (exactly
the declared length).  Multi-level extensions are rejected.  Verified
natively: `12 3 5`.

**M35 — record aggregate literals**: a record-typed variable may be
assigned a literal `{field = value, ...}` (whole-record copy RHS).
  Components are emitted in declaration order; fields not named fall
  back to their defaults (hidden/private components included), scalar
  fields accept the usual literal widening (INTEGER into REAL etc),
  and extension types are not yet supported.  Works for local records
  and imported exported records (`a := {x = 61, y = 20}` on a
  `Math.P`).  Verified natively: `11 9 7.000` and `81`.

**M34 — SET ranges and CHAR elements**: set literals accept
INTEGER-literal ranges (`{0 .. 5, 7, 9 .. 11}`) and CHAR elements;
`IN` accepts a CHAR left operand too.  CHAR operands are converted
with `Character'Pos` into the 0..31 bit space, so the classic
set-of-CHAR idiom works for ordinals that fit (`CHR(3) IN s`,
`c IN s`) and out-of-range ordinals like `CHR(65)` are simply never
members.  Ranges must lie in 0..31.  Verified natively:
`11 22 33 44 55`.

**M33 — string equality and ordering**: whole string values compare
with `= # < <= > >=`.  A generated `O2c_S_Cmp` helper compares the
NUL-terminated content of two String values (char-array variables may
be padded with NULs, so `m1 = "hi"` and two `Line` variables holding
`"hi"` both compare equal; ordering is lexicographic).  The comparison
branch in Parse_Expr rewrites the operator to `O2c_S_Cmp(a, b) <op>
0`.  Verified natively: `1 2 3 4` for equal / not-equal / less /
less-or-equal.

**M32 — nested procedures**: a procedure body may declare further
procedures (`PROCEDURE` sections among its local CONST/TYPE/VAR
declarations).  Nested procedures close over the enclosing
procedure's parameters and locals and over module variables, may be
recursive, cannot be exported, and cannot declare type-bound
procedures; nested functions work in expressions.  Verified natively:
Bump and Twice nested in Outer update the outer local `t` (7) and the
module counter (12).

**M31 — ambiguous multi-library overrides for widened dispatch**:
shadows now chain instead of collapsing: each library's base-view
shadow falls back to the previously-registered shadow for the same
(base, method) rather than straight to the base module's dispatcher
(adding the body `with` for it), and callers use the outermost
shadow.  Two independent libraries can both override the same base
method, and a single base-typed pointer dispatches to whichever
override its object actually has.  In the A/B/C harness a Shape
pointer prints `25` when it holds a B.Circle and `107` when it holds
a C.Ball.

**M30 — widened-pointer dispatch for method functions**: base-view
shadows now cover method *functions* too: a library exporting a
function-method override on a subtype of an imported type also exports
a `function M_Any_Disp_O2c_<Base> ... return T` shadow whose body
returns the library override for its subtree and otherwise returns the
base module's dispatcher; expression call sites through base-typed
pointers route through it.  In the A/B/C harness a Circle reached via
a Shape pointer prints `25` for `.Val()` (override `x*10+r`) while a
plain Shape prints `3`.

**M29 — widened-pointer dispatch across packages**: when a library
exports a procedure-method override on a subtype of an imported
exported type, it also exports a *shadow dispatcher on the base view*
(`Widen_Any_Disp_O2c_Shape`).  A caller holding a base-typed pointer
(`A.PShape`) that was widened to the library's subtype (`B.PCircle`)
dispatches through the shadow: the extending library's override runs
for its own subtree and everything else falls back to the base
module's dispatcher.  Verified in an A/B/C harness: a Circle reached
through a Shape pointer prints `31` (override `+k*10`) while a plain
Shape prints `3` (base `+k`).  Function-method shadows and ambiguous
multi-library overrides are documented as not covered.

**M28 — whole-record copies out of module VARIABLEs**: a local
variable of an imported RECORD type can now take its value from an
exported module VARIABLE of the same type (`a := Math.origin`), the
reverse of M22.  The whole-copy statement path accepts a qualified
module RECORD VARIABLE as its right-hand side when its catalog type
matches the left-hand side; the demo prints `99` for a copy of
`Math.origin` made after setting its fields to 88 and 11.

**M27 — exported-method overrides across packages**: a library may
export a RECORD that extends an imported exported type and export a
method overriding one of that type's exported methods (`Geo.Box` over
`Math.Point` overriding `Sum*`).  Capture accepts foreign extension
parents (and adds the `with`), the override dispatcher is exported
from the extending module, and importer calls resolve to the deepest
override through the catalog (XM_Chain), so a `Geo.Box` variable in
Hello dispatches to Geo's `Sum` (printing `39`).  Dispatch through a
pointer widened across module boundaries is documented as
out of scope.

**M26 — opaque pointers**: an exported `POINTER TO` may designate a
*private* RECORD declared after the pointer (`Handle* = pointer to
HandleDesc`; `HandleDesc` stays out of the export catalog).  The
defining module shows the incomplete/access/full record in its spec
so the Ada type exists, but importers only ever see the pointer: they
declare variables, assign, compare to NIL and pass it to the module's
exported procedures/functions (`Math.Make(9)` / `Math.Get(hd)`).
`NEW` on an opaque pointer and `^` dereference from an importer are
rejected with M26 errors.  Native demo prints `9`.

**M25 — predeclared functions**: the standard functions are
recognized case-insensitively like `LEN`/`NEW`: `ORD(ch)` →
`Character'Pos`, `CHR(i)` → `Character'Val`, `ABS(x)` for
INTEGER/LONGINT/REAL, `ODD(i)` for INTEGER/LONGINT, and the `INC(x
[, n])` / `DEC(x [, n])` statements on INTEGER/LONGINT variables
(literal steps on LONGINT, matching the LONGINT mixing rule).  The
demo prints `53 1 65 66 10-4`.

**M24 — cross-module type composition**: exported shapes may now
reference another module's exported types.  Record fields accept a
qualified imported type (`Rect* = record p*, q*: Math.Point ...` in a
module that imports Math), the export catalog stores the reference
under its true owner, and the importer's type synthesis imports the
foreign module's shapes on demand, so a `Geo.Rect` variable in Hello
gives field access through to `Math.Point` with export marks
enforced.  Package specs that reference other modules get the needed
`with` clauses, and libraries that only export types emit a spec-only
unit (no package body).  The demo prints `17` for a composed
`Geo.Rect` built from two `Math.Point`s.

**M23 — extend an imported RECORD type**: an importer can now
write `type P3 = record (Math.Point) z: integer end;` — the parent
may be an imported exported RECORD, emitted as an Ada type extension
over the package type.  Inherited exported fields stay accessible and
exported methods of the base resolve through the catalog chain
(XM_Chain), so `px.Scale(2)` calls the Math dispatcher with the
derived record as the class-wide receiver; the importer may add its
own methods on the subtype (statically bound).  Guards reject
declaring methods directly on an imported type and exporting a
method that overrides an imported base method (dynamic overrides
across packages remain M24).

**M22 — field export marks, whole-record module vars, SET
fields**: fields of exported RECORD types may now carry `name*`
export marks; the record still emits whole into the spec (Ada has no
component hiding) but the compiler gates importer `.field` access on
the mark, so modules keep private fields (`tag`) and exported types
may carry SET fields.  Whole-record assignment to an exported module
VARIABLE now works from a same-typed local variable or another
module VARIABLE (`Math.origin := a`); the demo prints `55` for it.

**M21 — shared support types, open arrays, SET vars**: every
multi-module build now emits a small `O2c_Types` package
(`O2c_Int_Arr`, `O2c_Bool_Arr`, `O2c_Set`) that every unit withs and
uses instead of declaring its own, so library and importer actually
share those Ada types.  That unlocks exported procedures taking
open-ARRAY formals (`SumArr*(a: array of integer): integer`, called
from an importer with a fixed array) and exported SET VARIABLEs
(`var marks*: set`) whose values an importer can assign, union and
test with `IN`.  The demo prints `... 27 28 406` at the end.

**M20e — exported fixed ARRAY types**: a `TYPE name* = ARRAY n
OF ...` is emitted into the package spec; numeric arrays put the
shared `O2c_Int_Arr`/`O2c_Bool_Arr` base in the spec too, char arrays
export as `String` subtypes, and arrays-of-exported-type work.  An
importer declares `var w: Math.Vec`, indexes it, takes `len(w)`, and
passes it to exported procedures taking a named fixed ARRAY formal
(declared `VAR`); the export catalog carries the array shape so the
designator engine and value initialisation behave like local arrays.
The demo fills a `Math.Vec` via `Math.Fill`, printing `203` at the
end.  Exported records may now carry fields of exported array types.

**M20f — exported RECORD VARIABLEs**: a module-level VARIABLE
whose type is an exported RECORD of the same module (`var origin*:
Point`) is emitted into the package spec and exported through the
catalog; importers read and write its fields with qualified designator
chains (`Math.origin.x := 77`).  Its spec line is deferred until after
the type's primitives so Ada keeps the method dispatchers primitive.
The demo sets `Math.origin` and prints `141` at the end.

**M20c — exported type-bound methods**: a procedure method
marked `name*` on an exported RECORD type (`procedure (var p: Point)
Scale*(k: integer)`) gets an exported dispatcher
`<Method>_Disp_O2c_<Type>` in the package spec whose body carries
the tag chain over the module's subtype tree; importers call it as a
plain `obj.Method(...)` on their imported-typed variables and the
compiler resolves the deepest bound method through the exported-method
catalog.  The demo calls `a.Scale(3)` and the method function
`a.Sum()` on a `Math.Point`, printing `309` twice at the end.
Function-method calls now import too (they resolve in expressions via
the catalog and call the exported function dispatcher).

**M20b — exported procedures on exported types**: library
procedures marked `name*` may now take VAR RECORD parameters and
POINTER parameters of the exported types of the same module, and
return exported POINTER types (`Translate*(var p: Point; ...)`,
`Next*(l: Node): Node`).  Importers call `Math.Translate(a, 1, 2)`
and `tx := Math.Next(hx)`; the catalog records formal and result
types as qualified names and the call site imports them, so VAR
checks and pointer typing behave like local calls.  Type-bound
procedures (methods) across modules, open-ARRAY and fixed-ARRAY
exports, and SET or record-typed exported VARIABLEs remain M20c.

**M20a — cross-module data types**: library `TYPE`
declarations marked `name*` are emitted into the package spec and
recorded in a name-based catalog.  `RECORD` (scalar/exported-record or
-pointer fields; SET and array fields rejected), `POINTER TO` (target
must be an exported RECORD), and extensions over an exported base
work.  An importer writes `var p: Math.Point` (or a POINTER such as
`Math.Node`); the compiler synthesises the exported shapes into its
type table, so `NEW`, `^` deref, `.field` chains, whole-record copies
and pointer sharing behave like local types.  The demo builds and
walks a `Math.Node` list, copies a `Math.Point`, calls `Math.Translate`
(VAR record), `Math.Next` (pointer result) and the exported method
`a.Scale(3)`, printing `100 100 103 60 309` at the time of M20c.

**M19 — modules**: `module M; import Out, Other;` compiles from
separate source files: `O2c_Compiler.Compile_Multi` turns each library
module into an Ada package spec+body and the command module into the
main procedure.  Exported `CONST`/`VARIABLE`/`procedure*` names live in
the package spec and an export catalog; importers use qualified
`M.name` reads, writes and calls, and Ada elaboration runs library
module initialisation before the importer body.  The demo splits into
`samples/hello.ob2` (command, now `import Out, Math`) and
`samples/math.ob2` (library exporting `Pi*`, `count*`, `Sqr*`,
`SetBase*`, `Bump*`); the regression asserts the final demo tail
(now `... 406`).

**M18 — REAL**: `REAL` maps to Ada `Float`.  Literals carry a
decimal point (`1.5`, `6.25`); `+ - * /` arithmetic (division is now
real), unary sign, comparisons and equality work, mixing with
INTEGER is allowed for plain literals (widened) and INTEGER
variables convert on assignment/argument/return.  `Out.Real(x, w)`
prints a fixed three-decimal value via a generated helper.  The demo
computes `6.25 / 2.5` and prints `2.500`.

**M17 — SET and LONGINT**: `SET` maps to an Ada modular
type (`O2c_Set is mod 2**32`, `with Interfaces`), with literal sets
`{e1, e2, …}`, union `+`, difference `-`, intersection `*`,
symmetric difference `/`, membership `e IN s`, subset `<=`/`>=` and
equality `= #`.  `LONGINT` maps to Ada `Long_Integer`; mixing
LONGINT with INTEGER is an error except plain numeric literals,
which widen (documented deviation), so `l := l + 1` and `l * 2`
work while `l := i` (INTEGER variable) is rejected.  Both types work
in vars, params, returns and record fields.  The demo tests
membership and difference on `s2 := {2, 4, 6}` and counts a LONGINT
to 60.

**M16 — record-typed fields and nested arrays**: record
fields may name an earlier RECORD or ARRAY type, and arrays may take
an earlier ARRAY/RECORD type as their element type (so nested and
multi-dimensional arrays like `Mat = array 2 of Row` and records
holding arrays compile).  Value initializers are generated
recursively (`(others => (others => 0))` for arrays of arrays, full
aggregates for records in records).  The designator chain now walks
`.field` / `^` / `[i]` selectors over record, pointer and array
values, so reads and writes like `in1.p.a`, `a[i][j]` and
`w.m[0][1]` work (char arrays keep the +1 Ada index rule at the
right nesting level).  The demo sets `sac.m[0][1] := 3`,
`sac.m[1][2] := 4` and reads the sum back.

**M15 — method functions (return values)**:
type-bound procedures may now declare a return type
(`procedure (var c: Circle) Ring: integer;`).  Each method function
gets a dispatcher function per bound record (spec emitted at its
declaration, body generated after every method is known) whose tag
chain returns the runtime-appropriate implementation, so
`circ.Ring()` works in expressions with dynamic dispatch intact
(`Out.Int(circ.Ring(), 0)`).  Calling a method function as a
statement is rejected.

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

The module/import epic and the whole README-tracked follow-up list are
shipped (M19-M29).  Remaining: ambiguous multi-library overrides for widened dispatch,
plus the documented deviations (case-insensitive keywords;
LONGINT/INTEGER mixing).

## Build

`AEGIR_ROOT` must point at the aegir checkout. It is **required** and
has no default (no machine-specific fallback), so CI fails loudly:

    make build AEGIR_ROOT=/path/to/aegir     # -> crate/bin/o2c.elf

## End-to-end pipeline (verified)

`tests/run_m1.sh` runs the whole dogfood chain in two Aegir boots:

1. Build `crate/bin/o2c.elf` and boot a quiet initrd
   (`make run INITRD_MODE=min O2C_ROOT=../o2c`) that stages the demo
   module sources (`Tests/O2cLib/Hello.ob2`, `Tests/O2cLib/Math.ob2`)
   plus the o2c and hello ELFs.
2. o2c reads the module files from the initrd, compiles them with
   `O2c_Compiler.Compile_Multi` and prints every generated Ada unit
   (`o2c_types.ads`, `math.ads`, `math.adb`, `hello.adb`) as `O2C|`
   lines between `--- unit <file> ---` / `--- unit end ---` markers,
   finishing with `--- ada end ---`.
3. run_m1 reconstructs the units on the host, gprbuilds the
   multi-unit program with the aegir runtime chain, and boots it as
   `Tests/Hello`.
4. Boot 2 asserts the demo's final console line (the cross-module
   `406` from `Math.SumArr`).

Verified: `tests/run_m1.sh` PASS (both boots, first attempt).
