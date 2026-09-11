# `.obc` image container — format v1 (spec)

Status: **specification** — the container is fixed here; the opcode table is
listed as reserved ranges only, because its shape follows the instruction-set
decision (stack vs register).  Implemented by the `o2c` bytecode emitter and
read by `vm/`.  See `docs/bytecode-vm.md` for the plan and milestones.

## Principles

1. **Flat, byte-oriented, little-endian.**  No native structs in the file, so
   a host build of the VM reads the same bytes Aegir does.  All multi-byte
   integers are little-endian; `u16`/`u32`/`u64` are unsigned.
2. **Deterministic.**  No timestamps, no host paths, no unordered tables.
   Tables are emitted in a fixed order (sorted by name where an order is not
   semantically meaningful), so compiling the same sources twice yields
   byte-identical images.
3. **Append-only opcodes and sections**, exactly like syscall/ABI numbers:
   never renumber, never repurpose.  New opcodes go in reserved space; new
   sections get new ids.
4. **A program is one self-contained image.**  The compiler already resolves
   the whole module closure in one run (main + builtins + `-l` libs), so v1
   packages every module of the program into a single image with one entry
   point.  Per-module images and dynamic loading are explicitly **out of scope
   for v1** (and would need libgc's `DYNAMIC_LOADING` support later).
5. **Verifiable.**  Every static property the VM relies on (section
   alignment, code offsets, operand-stack depth, type references, frame slot
   counts) is checkable before the first instruction runs.  The loader rejects
   anything it cannot verify rather than trusting the image.

## Header (fixed 64 bytes, at offset 0)

| off | size | field | v1 value / meaning |
|-----|------|-------|--------------------|
| 0x00 | 4 | `magic` | `"O2CB"` (0x4F 0x32 0x43 0x42) |
| 0x04 | 2 | `version_major` | 1 |
| 0x06 | 2 | `version_minor` | 0 |
| 0x08 | 2 | `ptr_size` | 8 |
| 0x0A | 2 | `endian` | 1 = little |
| 0x0C | 2 | `section_count` | number of section-table entries |
| 0x0E | 2 | `reserved0` | 0 |
| 0x10 | 8 | `section_table_off` | file offset of the section table |
| 0x18 | 8 | `code_off` | file offset of the code section (also in the table) |
| 0x20 | 4 | `n_imports` | imported modules |
| 0x24 | 4 | `n_exports` | exported entities |
| 0x28 | 8 | `total_size` | file size, must equal the real size |
| 0x30 | 8 | `flags` | bit0 descriptors, bit1 REAL/LONGREAL used, bit2 has DEBUG, rest 0 |
| 0x38 | 8 | `entry` | code offset of the module-init entry (program body) |

A reader must reject: a bad magic; `version_major` it does not know; a
`version_minor` **greater** than the one it was built for (forward
incompatibility) — but it must *accept* a smaller minor and ignore section ids
and trailing data it does not recognise.

## Section table

`section_count` entries, each 24 bytes: `id` (u32), `flags` (u32), `off`
(u64), `size` (u64).  Sections are concatenated in table order; each starts at
an 8-byte boundary (padding is zero).

| id | name | contents |
|----|------|----------|
| 1 | `IMPORT` | imported module names + the signatures this image needs |
| 2 | `EXPORT` | exported consts/types/vars/procs with their image offsets |
| 3 | `TYPES` | type descriptors (layout + method table + pointer-content flag) |
| 4 | `CONST` | constant pool: string bytes, REAL/LONGREAL literals, SET masks |
| 5 | `DATA` | module globals with their initial values (image copy) |
| 6 | `CODE` | bytecode, procedure entries, and per-procedure metadata |
| 7 | `DEBUG` | optional: source file names, line table, procedure names |
| 8 | `STACKMAP` | per-code-offset operand-stack types (see "Roots") |
| 9– | reserved | new sections take the next id; never reuse |

`flags` per section: bit0 = mandatory (loader must understand the *id*);
bit1 = strippable (`DEBUG`, `STACKMAP` may be dropped on request, at the cost
of precise GC / symbols).

## Descriptors (section `TYPES`)

Each descriptor: `kind` (u8), `flags` (u8), `size` (u16, bytes of an object
body for records/arrays-fixed), `name_ref` (u32 into `CONST`), then
kind-specific tail:

- **BASIC** — one of BOOLEAN, CHAR, INTEGER, REAL, LONGREAL, SET, STRING,
  NILT, plus the VM's `ANY` (used for guards/`WITH`).
- **ARRAY** — `elem_desc` (u32), `open` (u8: 0 fixed, 1 open/len at
  runtime), `len` (u32, when fixed).
- **RECORD** — field list: repeated `{ name_ref, field_desc, offset }`;
  terminated by a zero name_ref.  `base` (u32) points at the base record
  descriptor for an extension (0 = none), and `methods` (u32) points at the
  method table (exports only).
- **POINTER** — `target_desc` (u32); `NIL` is a distinguished null target.
- **PROCEDURE** — parameter/result signature refs (for type guards and for
  the native-module bridge).

**`flags` bit0 (`has_ptrs`) is load-bearing:** it tells the VM whether objects
of this type may contain pointers.  It drives (a) which allocation call an
object gets once libgc is in (`GC_malloc` vs `GC_malloc_atomic` — an object
that cannot contain pointers must be allocated atomic or it retains garbage
forever), and (b) whether the VM scans the body when enumerating roots.

## Code section and per-procedure metadata

`CODE` begins with a `n_procs` u32 and `n_procs` procedure records:
`code_off` (u32, relative to the code base), `frame_slots` (u32 locals),
`nparams` (u16), `nresults` (u16), `stack_max` (u32, statically computed
operand-stack high-water mark), `stackmap_off` (u32, 0 if absent),
`line_ref` (u32 into `DEBUG`, 0 if stripped).  Procedure bodies follow,
padded to 8 bytes.

The **entry** in the header is the code offset of the module body — the code
the VM runs after loading and initializing globals.

## Roots and GC (why `STACKMAP` exists)

A collector needs to know which words are pointers.  Because the emitter
knows the static type of everything it pushes, the VM does **not** have to
guess: `STACKMAP` may hold, per code offset, the type of every live operand
stack slot and frame slot that can hold a pointer.  v1 allows two modes:

- **absent (`STACKMAP` stripped)**: roots are found conservatively by
  scanning the VM stack window and the globals image (correct, but interior
  pointers retain garbage);
- **present**: roots are enumerated precisely, which is the design the plan
  is aiming at.

Either way the VM passes root *ranges* to libgc (`GC_add_roots`), so the
collector swap in M59 does not depend on which mode an image was built with.

## Opcodes (v1) — stack form

Decisions behind this table (`docs/bytecode-vm.md`): the **wire format is a
stack machine** with *typed* opcodes; the three-address IR lives underneath, so
an optimizing tier can be added through the escape range without a format
break.  The table is **append-only**, exactly like syscall/ABI numbers.

**Encoding.** One opcode byte, then its operands, little-endian, no padding
between instructions.  v1 uses wide, verifiable operands: `u8`, `u16`, `u32`,
`i32`; jump/code targets are **absolute u32 offsets into the code section**
(resolved and range-checked at load time).  Short jumps and fused forms are
reserved for the optimizing tier, which is why the escape prefix exists.

**Stack effect** is written `[before] -> [after]`, top of stack last.

**Storage rule (v1).** Every scalar is a **full 8-byte slot** — in locals,
globals, array elements and record fields alike.  `CHAR` is a word holding
0..255; `SET` is a 64-bit word.  No packed layouts in v1, which is what lets
the `_I`/`_R`/`_P` families be complete without width variants; a compact
layout is a later descriptor-flag optimization.  `REAL` and `LONGREAL` share
the `R` ops and the same 8-byte storage (both are 64-bit in the Aegir RTS —
only *formatting* differs), so there are no separate `L` arithmetic ops; if
`LONGREAL` ever widens, those land in reserved space.

`_P` always means "pointer-sized and pointer-bearing": those slots are scanned
as roots and the opcodes that produce them are the ones the GC maps care about.

### `0x00–0x0F` — VM control and stack

| op | mnemonic | operands | stack | notes |
|----|----------|----------|-------|-------|
| 0x00 | `NOP` | — | `[] -> []` | |
| 0x01 | `HALT` | — | `[] -> []` | normal program end |
| 0x02 | `DUP` | — | `[a] -> [a,a]` | |
| 0x03 | `DROP` | — | `[a] -> []` | |
| 0x04 | `SWAP` | — | `[a,b] -> [b,a]` | |
| 0x05 | `ASSERT_FAIL` | u32 msg ref into `CONST` | `[] -> []` | predeclared `ASSERT` |
| 0x06 | `TRAP` | u8 kind | `[] -> []` | runtime error, see kinds below |
| 0x07–0x0F | reserved | | | |

`TRAP` kinds (u8): 0 = index out of range, 1 = `NIL` dereference, 2 = type
guard failure, 3 = division by zero, 4 = `CASE` with no matching label
(should not occur — the emitter adds the else path), 5 = value out of range
(`CHR`/`ORD`/set index), 6 = explicit `HALT` request from a native.

### `0x10–0x2F` — loads, stores, aggregates

| op | mnemonic | operands | stack | notes |
|----|----------|----------|-------|-------|
| 0x10 | `LOAD_L` | u16 slot | `[] -> [v]` | |
| 0x11 | `STORE_L` | u16 slot | `[v] -> []` | |
| 0x12 | `LOAD_G` | u32 global idx | `[] -> [v]` | |
| 0x13 | `STORE_G` | u32 global idx | `[v] -> []` | |
| 0x14 | `LOAD_CONST` | u32 pool idx | `[] -> [v]` | INTEGER/CHAR/BOOLEAN/SET |
| 0x15 | `LOAD_ADDR_L` | u16 slot | `[] -> [addr]` | `VAR` params, arrays |
| 0x16 | `LOAD_ADDR_G` | u32 global idx | `[] -> [addr]` | |
| 0x17 | `LOAD_IND_I` | — | `[addr] -> [v]` | |
| 0x18 | `LOAD_IND_R` | — | `[addr] -> [v]` | REAL/LONGREAL |
| 0x19 | `LOAD_IND_P` | — | `[addr] -> [ptr]` | root-bearing |
| 0x1A | `STORE_IND_I` | — | `[addr,v] -> []` | |
| 0x1B | `STORE_IND_R` | — | `[addr,v] -> []` | |
| 0x1C | `STORE_IND_P` | — | `[addr,ptr] -> []` | |
| 0x1D | `LOAD_IDX_I` | — | `[arr,idx] -> [v]` | bounds-checked, `TRAP` 0 |
| 0x1E | `LOAD_IDX_R` | — | `[arr,idx] -> [v]` | |
| 0x1F | `LOAD_IDX_P` | — | `[arr,idx] -> [ptr]` | |
| 0x20 | `STORE_IDX_I` | — | `[arr,idx,v] -> []` | |
| 0x21 | `STORE_IDX_R` | — | `[arr,idx,v] -> []` | |
| 0x22 | `STORE_IDX_P` | — | `[arr,idx,ptr] -> []` | |
| 0x23 | `LOAD_FLD_I` | u16 byte off | `[rec] -> [v]` | offset pre-validated against the descriptor |
| 0x24 | `LOAD_FLD_R` | u16 | `[rec] -> [v]` | |
| 0x25 | `LOAD_FLD_P` | u16 | `[rec] -> [ptr]` | |
| 0x26 | `STORE_FLD_I` | u16 | `[rec,v] -> []` | |
| 0x27 | `STORE_FLD_R` | u16 | `[rec,v] -> []` | |
| 0x28 | `STORE_FLD_P` | u16 | `[rec,ptr] -> []` | |
| 0x29 | `ARRAY_LEN` | — | `[arr] -> [len]` | open arrays |
| 0x2A | `ALLOC_NEW` | u32 desc ref | `[] -> [ptr]` | zeroed object; `has_ptrs` picks GC_malloc vs atomic |
| 0x2B | `ALLOC_NEW_ARR` | u32 desc ref | `[len] -> [ptr]` | open array |
| 0x2C | `LOAD_CONST_P` | u32 pool idx | `[] -> [ptr]` | `NIL` |
| 0x2D | `LOAD_CONST_R` | u32 pool idx | `[] -> [v]` | REAL/LONGREAL literal |
| 0x2E | `COPY_BYTES` | — | `[src,dst,len] -> []` | array/record/string assignment; non-moving collector assumed |
| 0x2F | reserved | | | |

### `0x30–0x5F` — INTEGER, bit and set arithmetic

| op | mnemonic | stack | notes |
|----|----------|-------|-------|
| 0x30 | `IADD` | `[a,b] -> [a+b]` | |
| 0x31 | `ISUB` | `[a,b] -> [a-b]` | |
| 0x32 | `IMUL` | `[a,b] -> [a*b]` | |
| 0x33 | `IDIV` | `[a,b] -> [a DIV b]` | `TRAP` 3 on zero |
| 0x34 | `IMOD` | `[a,b] -> [a MOD b]` | |
| 0x35 | `INEG` | `[a] -> [-a]` | |
| 0x36 | `IABS` | `[a] -> [ABS a]` | |
| 0x37 | `IEQ`  | `[a,b] -> [bool]` | |
| 0x38 | `INE`  | `[a,b] -> [bool]` | |
| 0x39 | `ILT`  | `[a,b] -> [bool]` | |
| 0x3A | `ILE`  | `[a,b] -> [bool]` | |
| 0x3B | `IGT`  | `[a,b] -> [bool]` | |
| 0x3C | `IGE`  | `[a,b] -> [bool]` | |
| 0x3D | `SET_UNION`     | `[s,t] -> [s+t]` | `+` on SET |
| 0x3E | `SET_INTERSECT` | `[s,t] -> [s*t]` | `*` on SET |
| 0x3F | `SET_DIFF`      | `[s,t] -> [s-t]` | `-` on SET |
| 0x40 | `SET_SYMDIFF`   | `[s,t] -> [s/t]` | `/` on SET |
| 0x41 | `SET_EQ` | `[s,t] -> [bool]` | |
| 0x42 | `SET_NE` | `[s,t] -> [bool]` | |
| 0x43 | `SET_IN` | `[idx,s] -> [bool]` | `i IN s`, `TRAP` 5 if idx outside 0..63 |
| 0x44 | `SET_SINGLE` | `[idx] -> [set]` | `{i}` |
| 0x45–0x5F | **reserved for the optimizing tier** | | fused `local op const` integer forms (`INC`/`DEC` loops) |

### `0x60–0x7F` — CHAR, BOOLEAN and string/array comparisons

| op | mnemonic | stack | notes |
|----|----------|-------|-------|
| 0x60 | `CEQ` | `[a,b] -> [bool]` | CHAR comparisons |
| 0x61 | `CNE` | `[a,b] -> [bool]` | |
| 0x62 | `CLT` | `[a,b] -> [bool]` | |
| 0x63 | `CLE` | `[a,b] -> [bool]` | |
| 0x64 | `CGT` | `[a,b] -> [bool]` | |
| 0x65 | `CGE` | `[a,b] -> [bool]` | |
| 0x66 | `BEQ` | `[a,b] -> [bool]` | BOOLEAN comparisons |
| 0x67 | `BNE` | `[a,b] -> [bool]` | |
| 0x68 | `BTEST` | `[b] -> [bool]` | BOOLEAN as a value (used by `IF`) |
| 0x69 | `STR_EQ` | `[a,b] -> [bool]` | NUL-terminated char arrays |
| 0x6A | `STR_NE` | `[a,b] -> [bool]` | |
| 0x6B | `STR_LT` | `[a,b] -> [bool]` | |
| 0x6C | `STR_LE` | `[a,b] -> [bool]` | |
| 0x6D | `STR_GT` | `[a,b] -> [bool]` | |
| 0x6E | `STR_GE` | `[a,b] -> [bool]` | |
| 0x6F | `STR_COPY` | `[dst,src] -> []` | `COPY`, truncating + NUL-terminating |
| 0x70 | `ORD` | `[c] -> [i]` | CHAR -> INTEGER |
| 0x71 | `CHR` | `[i] -> [c]` | `TRAP` 5 outside 0..255 |
| 0x72–0x7F | reserved | | |

### `0x80–0x9F` — REAL / LONGREAL

| op | mnemonic | stack | notes |
|----|----------|-------|-------|
| 0x80 | `RADD` | `[a,b] -> [a+b]` | REAL and LONGREAL share these |
| 0x81 | `RSUB` | `[a,b] -> [a-b]` | |
| 0x82 | `RMUL` | `[a,b] -> [a*b]` | |
| 0x83 | `RDIV` | `[a,b] -> [a/b]` | IEEE semantics, no trap |
| 0x84 | `RNEG` | `[a] -> [-a]` | |
| 0x85 | `RABS` | `[a] -> [ABS a]` | |
| 0x86 | `REQ` | `[a,b] -> [bool]` | |
| 0x87 | `RNE` | `[a,b] -> [bool]` | |
| 0x88 | `RLT` | `[a,b] -> [bool]` | |
| 0x89 | `RLE` | `[a,b] -> [bool]` | |
| 0x8A | `RGT` | `[a,b] -> [bool]` | |
| 0x8B | `RGE` | `[a,b] -> [bool]` | |
| 0x8C | `I2R` | `[i] -> [r]` | `FLT` |
| 0x8D | `R2I_ROUND` | `[r] -> [i]` | round to nearest, Oberon `ENTIER`-free conversion |
| 0x8E | `R2I_TRUNC` | `[r] -> [i]` | truncate toward zero |
| 0x8F | `LREAL_MARK` | — | escape marker for future widened LONGREAL ops (currently a no-op) |
| 0x90–0x9F | reserved | | fused REAL forms |

### `0xA0–0xBF` — control flow

| op | mnemonic | operands | stack | notes |
|----|----------|----------|-------|-------|
| 0xA0 | `JMP` | u32 target | `[] -> []` | |
| 0xA1 | `JZ`  | u32 target | `[bool] -> []` | |
| 0xA2 | `JNZ` | u32 target | `[bool] -> []` | |
| 0xA3 | `CASE` | u32 case-table ref | `[v] -> []` | jump table; no match falls through |
| 0xA4 | `FOR_ENTER_I` | u16 var slot, i32 step, u32 else target | `[from,to] -> []` | direction from `from` vs `to`; stores `from`, jumps to `else` if the loop body never runs |
| 0xA5 | `FOR_NEXT_I` | u16 var slot, i32 step, u16 limit slot, u32 body target | `[] -> []` | `var := var ± step`, loop while in range |
| 0xA6 | `FOR_ENTER_C` | as `FOR_ENTER_I` | `[from,to] -> []` | CHAR loop variable |
| 0xA7 | `FOR_NEXT_C` | as `FOR_NEXT_I` | `[] -> []` | |
| 0xA8–0xBF | reserved | | | short `i8`/`i16` jumps for the optimizing tier |

`FOR_ENTER_*`/`FOR_NEXT_*` allocate **two hidden frame slots** (limit and
direction), **at the loop variable's slot + 1 (limit) and + 2 (direction)**:
the variable slot is the only one the opcode names, so the placement has to be
a convention, and this is it - a FOR inside a procedure therefore grows
`frame_slots` by three that the emitter accounts for in `frame_slots` — this is what makes
the Oberon-2 rule ("the step direction is decided by the initial comparison")
exact, and it keeps the loop limit out of the operand stack so nested loops and
procedure calls inside the body cannot disturb it.

`CASE` tables live in the `CONST` section as: `n` u32, then `n` entries of
`{lo u32, hi u32, target u32}` (a label is a range, matching Oberon `lo..hi`).
The emitter places the else branch immediately after `CASE`.

### `0xC0–0xDF` — calls and frames

| op | mnemonic | operands | stack | notes |
|----|----------|----------|-------|-------|
| 0xC0 | `CALL` | u32 code off | `[args...] -> [rets...]` | callee's locals *are* the parameter slots |
| 0xC1 | `RET` | — | `[v] -> []` | one result |
| 0xC2 | `RET_VOID` | — | `[] -> []` | |
| 0xC3 | `CALL_NATIVE` | u16 native idx, u8 arg count | `[args...] -> [rets...]` | builtin modules (Out, Files, …) |
| 0xC4 | `LOAD_X` | u16 slot | `[] -> [v]` | load from the caller's frame (display/static link access) |
| 0xC5 | `STORE_X` | u16 slot | `[v] -> []` | |
| 0xC6–0xDF | reserved | | | tail calls, varargs |

The native ABI is deliberately narrow: the VM marshals the operand stack into
a value array with descriptor references and calls an Ada procedure that
returns a status (0 = ok, non-zero = a `TRAP` kind).  Natives may **not** keep
VM pointers across the call — a native that wants to retain one must register
it as a root through the VM API (none currently needs to).

### `0xE0–0xEF` — OOP and dynamic types

| op | mnemonic | operands | stack | notes |
|----|----------|----------|-------|-------|
| 0xE0 | `GUARD` | u32 desc ref | `[ptr] -> [ptr]` | `WITH`/type guard; `TRAP` 2 on failure; `NIL` passes |
| 0xE1 | `TYPE_TEST` | u32 desc ref | `[ptr] -> [bool]` | descriptor-chain walk |
| 0xE2 | `DISPATCH` | u16 method idx | `[self,args...] -> [rets...]` | resolve through `self`'s descriptor method table |
| 0xE3 | `DESC_OF` | — | `[ptr] -> [desc_addr]` | for native bookkeeping / debugging |
| 0xE4–0xEF | reserved | | | fused guard+branch, inline caches |

### `0xF0–0xFF` — escape

| op | mnemonic | operands | stack | notes |
|----|----------|----------|-------|-------|
| 0xF0 | `EXT` | u8 sub-opcode, then its operands | as defined | unlimited future space; an unknown sub-opcode aborts loading |
| 0xF1–0xFF | reserved | | | |

Rules: an unknown opcode aborts loading with the code offset in the
diagnostic — never execute blind.  Opcodes are added inside these ranges only;
a full range takes the next free one, or an `EXT` form.

## Operands: widths, byte order, offset bases

Every operand is written at its natural width with **no padding between
instructions**, little-endian (the header's `endian = 1`):

| width | bytes |
|-------|-------|
| u8    | 1 |
| u16   | 2, low byte first |
| u32   | 4, low byte first |

### The one base to get right

`entry`, a procedure record's `code_off`, `CALL`'s operand and every jump
target are offsets **from the start of the `CODE` section payload** — the
byte holding `n_procs`, which means they **include** the procedure table that
follows it.  A one-procedure image's first instruction is therefore at offset
`4 + 24 = 28`, not 0.

Worth stating twice, because everything else in the format is relative to
nothing at all:

- **frame slots** are numbered from 0 *per procedure*, and a callee's locals
  **are** its parameter slots: `CALL` takes its arguments on the operand
  stack and leaves them in the callee's frame, lowest slot first;
- the **operand stack** is separate from the frames and is what `stack_max`
  bounds;
- `CONST` pool references and global indices are 0-based indices into their
  own sections.

`LOAD_L`/`STORE_L` carry a u16 slot, `LOAD_G`/`STORE_G` a u32 global index,
and jumps a u32 target that is absolute within the `CODE` payload — not a
relative displacement.

## Implemented today

The crate compiles the whole language to Ada; the bytecode emitter is a
parallel, deliberately partial consumer of the same parse.  So this table is
about the *emitter and the VM*, not about o2c's accepted input:

| area | emitted and executed |
|------|----------------------|
| stack, locals, globals | `DUP`, `DROP`, `LOAD_L`, `STORE_L`, `LOAD_G`, `STORE_G`, `LOAD_CONST` |
| arithmetic, comparison, sets | `ADD` … `GE`, `NEG`, `IABS`, `BTEST`, `ORD`, `CHR`; `SET_UNION`/`INTERSECT`/`DIFF`/`SYMDIFF`, `SET_EQ`/`NE`, `SET_IN`, `SET_SINGLE` (set literals; an element outside 0..63 traps) |
| control flow | `JMP`, `JZ`, `JNZ` (u32 target absolute in the `CODE` payload); `DUP`/`DROP` for stack shuffles |
| statements | `REPEAT`/`UNTIL` (a backward `JZ`, the mirror of `WHILE`), `CASE` (a comparison chain over a selector that stays on the stack, dropped once at the end), `FOR` (`FOR_ENTER_I`/`FOR_NEXT_I`; the loop variable is a frame slot and the limit and direction are the two hidden slots after it) |
| procedures | `CALL`, `RET`, `RET_VOID` — a declared procedure is emitted as its own procedure with its parameters as its lowest frame slots in order, and the module body is the last one; a procedure's variables are frame slots too, taken after its parameters |
| arrays | `LOAD_ADDR_G`, `LOAD_IDX_I`/`STORE_IDX_I` — a fixed INTEGER array is a run of scalar slots in `DATA`, one per element; an element's address is `LOAD_ADDR_G` of the first slot plus eight bytes per index, and the **emitter** bounds-checks the index (`TRAP` 0, both ends, since an address carries no length). The designator chain pushes the base before the index is evaluated and marks its leaf `D_Index`, so it never has to know whether the caller reads or assigns; the caller emits the access |
| records | `LOAD_FLD_I`/`STORE_FLD_I` — a record variable is a run of scalar slots like an array, and a field is the word at the record's address plus its offset. The descriptor fixes the layout, so the offset is a compile-time constant and there is no runtime bound to check; what makes that safe is that the emitter can only name an offset the descriptor defined. Only INTEGER fields reached directly from a record variable for now — a chain of records would need the offsets composed, and an extension's layout is shared with its parent |
| pointers | `LOAD_CONST_P` (NIL), and a pointer variable is one scalar slot, so assignment is an ordinary store and `=`/`/=` compare two addresses with `EQ`/`NE` (only equality - an ordering gate refuses pointer relations). A *bare* pointer used as a value is pushed by the factor's user-typed-variable branch: every variable with a user type enters that branch before the scalar one, and with no selector following, no designator path pushes its base, so that branch pushes it. `p.f` is a load of the slot (which holds the record's address) plus a field offset, and `p^` adds `LOAD_IND_I`. `NEW` and the descriptor table it needs are not implemented |
| allocation | `ALLOC_NEW` with a `TYPES` descriptor (section 3). Each descriptor is `kind`, `flags`, `size`, `name_ref` and a kind-specific tail; the operand names one by byte offset into that payload. RECORD descriptors are what `NEW` emits, sized `N_F * 8` because the layout is one scalar slot per field. `TYPES` is optional and is only present when a program allocates, so an image that allocates nothing keeps the older layout. The VM takes the object zeroed from a bump-allocated arena and pushes its address - the same address the field and indexed accesses already consume - and has no collector and no reset (it is loaded and run once per process) |
| REAL | `RADD` … `RGE`, `RNEG`/`RABS`, `I2R`, `R2I_ROUND`/`R2I_TRUNC` and `LOAD_CONST_R`; a real literal, and comparisons between two reals (a mixed INTEGER/REAL comparison needs an `I2R` and is refused rather than emitted wrong) |
| builtins | `CALL_NATIVE` (`Out.Int`, `Out.String`, `Out.Ln`, `Out.Real` - the VM formats a real exactly as `O2c_Put_Real` does, three digits after the point) |
| traps | `TRAP`, `ASSERT_FAIL` |

Everything else in the v1 opcode table is *defined* here, reports
`Not_Implemented` in the VM, and raises a clear front-end error rather than
emitting a wrong image — a construct outside the emitter's scope fails loudly
instead of silently producing a bad program.

The front end's scope today is the **module body** doing INTEGER/CHAR/BOOLEAN
work on module-level scalars.  A procedure record's `stack_max` is currently
the module's high-water mark: a conservative bound, which is all the verifier
needs, rather than the exact per-procedure figure.
