#!/usr/bin/env python3
"""Minimal .obc assembler for VM tests (docs/obc-image.md v1 container).

This exists so the VM can be exercised before the o2c bytecode emitter
lands -- and so the loader's negative tests have hand-built images to
reject.  It is a test tool, not a product: only the opcodes the thin
slice implements, one module body, no procedures.

Layout: header (64) | section table (3 * 24) | CONST | DATA | CODE.
CONST holds 8-byte pool words followed by string bytes (NUL-terminated);
a `str` constant also defines a pool word holding its own CONST offset,
which is what Out.String consumes.
"""
import struct, sys

OPS = {
    "NOP": (0x00, 0), "HALT": (0x01, 0), "DUP": (0x02, 0), "DROP": (0x03, 0),
    "ASSERT_FAIL": (0x05, 4), "TRAP": (0x06, 1),
    "LOAD_G": (0x12, 4), "STORE_G": (0x13, 4), "LOAD_CONST": (0x14, 4),
    "ADD": (0x30, 0), "SUB": (0x31, 0), "MUL": (0x32, 0), "DIV": (0x33, 0),
    "MOD": (0x34, 0), "NEG": (0x35, 0), "ABS": (0x36, 0),
    "EQ": (0x37, 0), "NE": (0x38, 0), "LT": (0x39, 0), "LE": (0x3A, 0),
    "GT": (0x3B, 0), "GE": (0x3C, 0),
    "BTEST": (0x68, 0), "ORD": (0x70, 0), "CHR": (0x71, 0),
    "JMP": (0xA0, 4), "JZ": (0xA1, 4), "JNZ": (0xA2, 4),
    "CALL_NATIVE": (0xC3, 3),
    "LOAD_L": (0x10, 2), "STORE_L": (0x11, 2),
    "CALL": (0xC0, 4), "RET": (0xC1, 0), "RET_VOID": (0xC2, 0),
    #  FOR opcodes carry several operands including a label, so they are
    #  encoded specially below rather than through the width table.
    "FOR_ENTER_I": (0xA4, 0), "FOR_NEXT_I": (0xA5, 0),
    "SET_UNION": (0x3D, 0), "SET_INTERSECT": (0x3E, 0), "SET_DIFF": (0x3F, 0),
    "SET_SYMDIFF": (0x40, 0), "SET_EQ": (0x41, 0), "SET_NE": (0x42, 0),
    "SET_IN": (0x43, 0), "SET_SINGLE": (0x44, 0),
    "LOAD_ADDR_G": (0x16, 4), "LOAD_FLD_I": (0x23, 2), "LOAD_FLD_R": (0x24, 2), "STORE_FLD_R": (0x27, 2), "LOAD_FLD_P": (0x25, 2), "STORE_FLD_P": (0x28, 2), "LOAD_CONST_P": (0x2C, 4), "ALLOC_NEW": (0x2A, 4), "STORE_FLD_I": (0x26, 2), "LOAD_IDX_I": (0x1D, 0), "STORE_IDX_I": (0x20, 0),
    "GUARD": (0xE0, 4), "TYPE_TEST": (0xE1, 4), "DISPATCH": (0xE2, 3),
    "YIELD": (0xE4, 0), "CALL_INDIRECT": (0xE5, 0),
    "DESC_OF": (0xE3, 0),
    "LOAD_CONST_R": (0x2D, 4),
    "RADD": (0x80, 0), "RSUB": (0x81, 0), "RMUL": (0x82, 0), "RDIV": (0x83, 0),
    "RNEG": (0x84, 0), "RABS": (0x85, 0), "REQ": (0x86, 0), "RNE": (0x87, 0),
    "RLT": (0x88, 0), "RLE": (0x89, 0), "RGT": (0x8A, 0), "RGE": (0x8B, 0),
    "I2R": (0x8C, 0), "R2I_ROUND": (0x8D, 0), "R2I_TRUNC": (0x8E, 0),
}
PROC_REC = 24
CONST_SLOT = 8


def assemble(text):
    words, strings = [], []          # pool words, string bytes
    pool_names, labels = {}, {}
    #  Type descriptors for the TYPES section: a name to a byte offset,
    #  which is what an ALLOC_NEW operand names.
    desc_names = {}
    table_names = {}      #  method table name -> its biased reference
    meth_fixups = []      #  (offset in types, the table's procedure names)
    proc_ids = {}         #  procedure name -> its 1-based id
    types = bytearray()
    globals_n, maxstack, entry = 0, 0, None
    #  PROC name slots nparams nresults: a procedure.  The module body is the
    #  last one (ENTRY names it); with no PROC at all the whole program is the
    #  body, which keeps single-procedure images byte-identical.
    n_procs = sum(1 for l in text.splitlines()
                  if l.split("#")[0].strip().upper().startswith("PROC "))
    procs = []
    table = 4 + max(n_procs, 1) * PROC_REC
    code = bytearray()
    pending = []                     # (index-in-code, name) fixups
    for raw in text.splitlines():
        line = raw.split("#")[0].strip()
        if not line:
            continue
        parts = line.replace(":", ": ").split()
        if ":" in parts[0]:          # label definition
            name = parts[0][:-1]
            labels[name] = table + len(code)
            parts = parts[1:]
            if not parts:
                continue
        op = parts[0].upper()
        if op == "GLOBALS":
            globals_n = int(parts[1]); continue
        if op == "MAXSTACK":
            maxstack = int(parts[1]); continue
        if op == "ENTRY":
            entry = parts[1]; continue
        if op == "PROC":
            #  name frame_slots nparams nresults
            if len(parts) != 5:
                raise SystemExit("obc_asm: PROC wants name slots nparams "
                                 "nresults")
            labels[parts[1]] = table + len(code)
            procs.append((labels[parts[1]], int(parts[2]), int(parts[3]),
                          int(parts[4])))
            proc_ids[parts[1]] = len(procs)   #  1-based, the order the
                                              #  procedure table gives them
            continue
        if op == "METHODS":
            #  METHODS table-name proc-name ...: a method table as `n` u32
            #  followed by n procedure ids.  Its reference is recorded for a
            #  DESC_REC to point at; the ids themselves are patched at the end
            #  because the procedures they name may be declared later.
            if len(parts) < 3:
                raise SystemExit("obc_asm: METHODS wants a name and at least "
                                 "one procedure")
            names = parts[2:]
            at = len(types)
            types += struct.pack("<I", len(names))
            types += b"\x00" * 4 * len(names)
            table_names[parts[1]] = at + 1
            meth_fixups.append((at + 4, names))
            continue
        if op == "DESC_REC":
            #  DESC_REC name size: a RECORD descriptor with no pointer
            #  fields.  kind 3 (RECORD), flags 0, size, name_ref 0, an empty
            #  field list (a zero name_ref terminates it), base 0, methods 0.
            if len(parts) not in (3, 4, 5):
                raise SystemExit("obc_asm: DESC_REC wants name size [base] "
                                 "[methods]")
            #  A reference is the offset plus one, so 0 can mean none: the
            #  first descriptor sits at offset 0.  `base` and `methods` are
            #  both stored in that form, and the walk reads `base` back at +12.
            #  '-' is an absent base or method table: zero, which means none.
            base = (desc_names[parts[3]]
                    if len(parts) >= 4 and parts[3] != "-" else 0)
            meth = (table_names[parts[4]]
                    if len(parts) == 5 and parts[4] != "-" else 0)
            desc_names[parts[1]] = len(types) + 1
            types += struct.pack("<BBHI", 3, 0, int(parts[2]), 0)
            types += struct.pack("<I", 0)      # end of the field list
            types += struct.pack("<II", base, meth)   # base, methods
            continue
        if op == "POOL_R":
            #  a REAL literal: its IEEE pattern goes in the word pool
            words.append(struct.unpack("<Q", struct.pack("<d",
                                                         float(parts[2])))[0])
            pool_names[parts[1]] = len(words) - 1
            continue
        if op in ("POOL", "STR"):
            #  POOL name value      -> a pool word
            #  STR  name "text"     -> a NUL-terminated string in CONST plus
            #                          a pool word holding its CONST offset
            name = parts[1]
            if op == "POOL":
                words.append(int(parts[2], 0))
            else:
                #  the literal may contain spaces: rejoin everything after
                #  the name, then strip the surrounding quotes
                lit = " ".join(parts[2:])
                if lit.startswith('"') and lit.endswith('"'):
                    lit = lit[1:-1]
                strings.append(lit.encode().decode("unicode_escape").encode()
                               + b"\x00")
                words.append(("str", len(strings) - 1))
            pool_names[name] = len(words) - 1
            continue
        if op not in OPS:
            raise SystemExit(f"obc_asm: unknown mnemonic {op}")
        opcode, nbytes = OPS[op]
        if op in ("FOR_ENTER_I", "FOR_NEXT_I"):
            #  FOR_ENTER_I slot step limit label  /  FOR_NEXT_I likewise:
            #  both name the hidden limit slot, and the direction is the slot
            #  after it.
            want = 4
            if len(parts[1:]) != want:
                raise SystemExit(f"obc_asm: {op} wants {want} operands")
            a = parts[1:]
            code.append(opcode)
            code += struct.pack("<H", int(a[0], 0))
            code += struct.pack("<i", int(a[1], 0))
            label = a[-1]
            code += struct.pack("<H", int(a[2], 0))
            pending.append((len(code), label))
            code += b"\x00" * 4
            continue
        code.append(opcode)
        args = parts[1:]
        if nbytes:
            if len(args) != (2 if op == "CALL_NATIVE"
                             else 3 if op == "DISPATCH" else 1):
                raise SystemExit(f"obc_asm: {op} wants "
                                 f"{2 if op == 'CALL_NATIVE' else 1} operand(s)")
            vals = []
            for a in args:
                if a in pool_names:
                    vals.append(pool_names[a])
                elif a in desc_names:
                    vals.append(desc_names[a])
                elif a.lstrip("-").isdigit():
                    vals.append(int(a))
                else:
                    vals.append(a)          # a code label: fix up later
            if op == "CALL_NATIVE":
                code += struct.pack("<HB", vals[0], vals[1])
            elif op == "DISPATCH":
                code += struct.pack("<HBB", vals[0], vals[1], vals[2])
            elif op in ("JMP", "JZ", "JNZ", "CALL") \
                    and isinstance(vals[0], str):
                pending.append((len(code), vals[0]))
                code += b"\x00" * 4
            else:
                if nbytes == 2:
                    code += struct.pack("<H", vals[0] & 0xFFFF)
                elif nbytes == 1:
                    code += struct.pack("<B", vals[0] & 0xFF)
                else:
                    code += struct.pack("<I", vals[0] & 0xFFFFFFFF)
    #  patch the method tables now that every procedure is known
    for at, names in meth_fixups:
        for k, nm in enumerate(names):
            if nm not in proc_ids:
                raise SystemExit("obc_asm: METHODS names unknown procedure "
                                 + nm)
            types[at + 4 * k:at + 4 * k + 4] = struct.pack("<I", proc_ids[nm])
    # patch jumps now that all labels are known
    for at, name in pending:
        if name not in labels:
            raise SystemExit(f"obc_asm: undefined label {name}")
        code[at:at + 4] = struct.pack("<I", labels[name])
    # CONST payload: pool words, then the string area
    str_off = len(words) * CONST_SLOT
    consts = bytearray()
    off = str_off
    for w in words:
        if isinstance(w, tuple):
            consts += struct.pack("<Q", off)
            off += len(strings[w[1]])
        else:
            consts += struct.pack("<Q", w & 0xFFFFFFFFFFFFFFFF)
    for s in strings:
        consts += s
    while len(consts) % 8:
        consts += b"\x00"
    data = b"\x00" * (globals_n * CONST_SLOT)
    if entry is None:
        entry = 0
    entry_off = labels.get(entry, 0)
    recs = b""
    if procs:
        for off, slots, nparams, nresults in procs:
            recs += struct.pack("<IIHHIII", off, slots, nparams, nresults,
                                maxstack, 0, 0)
    else:
        recs = struct.pack("<IIHHIII", entry_off, 0, 0, 0, maxstack, 0, 0)
    code_payload = struct.pack("<I", max(n_procs, 1)) + recs + bytes(code)
    while len(code_payload) % 8:
        code_payload += b"\x00"
    #  section sizes include their alignment padding: the VM slices the
    #  section as [off, off+size) and must cover the padded tail.
    def padded(p):
        return bytes(p) + b"\x00" * ((-len(p)) % 8)

    sections = [(6, padded(code_payload)), (4, padded(consts)), (5, padded(data))]
    if types:
        sections.append((3, padded(types)))
    base = 64 + 24 * len(sections)
    table, blob, off = b"", b"", base
    for sid, payload in sections:
        table += struct.pack("<IIQQ", sid, 1, off, len(payload))
        blob += payload
        off += len(payload)
    total = base + len(blob)
    header = (b"O2CB" + struct.pack("<HHHHHH", 1, 0, 8, 1, len(sections), 0)
              + struct.pack("<Q", 64) + struct.pack("<Q", 0)
              + struct.pack("<II", 0, 0) + struct.pack("<Q", total)
              + struct.pack("<Q", 1) + struct.pack("<Q", entry_off))
    assert len(header) == 64, len(header)
    return header + table + blob


if __name__ == "__main__":
    src = open(sys.argv[1]).read()
    out = assemble(src)
    with open(sys.argv[2], "wb") as fh:
        fh.write(out)
    print(f"obc_asm: {sys.argv[1]} -> {sys.argv[2]} ({len(out)} bytes)")
