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

## Reserved opcode ranges

The opcode table is fixed once the instruction style is chosen; the *space* is
reserved now, in the same append-only spirit as the syscall numbers:

| range | purpose |
|-------|---------|
| `0x00–0x0F` | VM control: NOP, HALT, breakpoint, stack discipline helpers |
| `0x10–0x2F` | local/global/constant loads and stores |
| `0x30–0x5F` | INTEGER arithmetic, bitwise, comparisons |
| `0x60–0x7F` | CHAR, SET, and string/array operations |
| `0x80–0x9F` | REAL and LONGREAL |
| `0xA0–0xBF` | control flow: jumps, `CASE` tables, `FOR` step variants |
| `0xC0–0xDF` | calls, frames, native (builtin-module) calls, returns |
| `0xE0–0xEF` | OOP: type guards, dynamic dispatch, type tests |
| `0xF0–0xFF` | escape prefix (multi-byte forms) and future extensions |

Rules: an unknown opcode aborts loading with a diagnostic naming the offset —
never execute blind.  Opcodes are added in these ranges only; if a range fills
up, the next free range (or a new escape form) is used.

## Versioning policy

- **minor** — new sections, new opcodes, new descriptor kinds, added header
  fields in the reserved area.  Older readers must still run the image by
  ignoring what they do not know, *unless* a section/opcode is marked
  mandatory.
- **major** — anything that changes existing layout or semantics (header
  field moves, opcode renumbering, frame layout).  A reader refuses a major it
  does not know.

## Verification plan (for the implementation)

- Round-trip: emit → load → disassemble → compare against the emitter's own
  IR dump (deterministic, so it can be a golden test).
- Negative tests: bad magic, future major, truncated section, section
  overlapping the header, code offset out of range, `stack_max` smaller than
  the computed high-water mark, descriptor reference out of range — the loader
  must reject all of them with a diagnostic, not crash.
- Byte-identity: compiling the same sources twice (and from two different
  working directories) yields identical images.
