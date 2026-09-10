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
}
PROC_REC = 24
CONST_SLOT = 8


def assemble(text):
    words, strings = [], []          # pool words, string bytes
    pool_names, labels = {}, {}
    globals_n, maxstack, entry = 0, 0, None
    code = bytearray()
    pending = []                     # (index-in-code, name) fixups
    for raw in text.splitlines():
        line = raw.split("#")[0].strip()
        if not line:
            continue
        parts = line.replace(":", ": ").split()
        if ":" in parts[0]:          # label definition
            name = parts[0][:-1]
            labels[name] = 4 + PROC_REC + len(code)
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
        code.append(opcode)
        args = parts[1:]
        if nbytes:
            if len(args) != (2 if op == "CALL_NATIVE" else 1):
                raise SystemExit(f"obc_asm: {op} wants "
                                 f"{2 if op == 'CALL_NATIVE' else 1} operand(s)")
            vals = []
            for a in args:
                if a in pool_names:
                    vals.append(pool_names[a])
                elif a.lstrip("-").isdigit():
                    vals.append(int(a))
                else:
                    vals.append(a)          # a code label: fix up later
            if op == "CALL_NATIVE":
                code += struct.pack("<HB", vals[0], vals[1])
            elif op in ("JMP", "JZ", "JNZ") and isinstance(vals[0], str):
                pending.append((len(code), vals[0]))
                code += b"\x00" * 4
            else:
                code += struct.pack("<I", vals[0] & 0xFFFFFFFF)
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
    code_payload = (struct.pack("<I", 1) + struct.pack("<IIHHIII", entry_off, 0,
                     0, 0, maxstack, 0, 0) + bytes(code))
    while len(code_payload) % 8:
        code_payload += b"\x00"
    #  section sizes include their alignment padding: the VM slices the
    #  section as [off, off+size) and must cover the padded tail.
    def padded(p):
        return bytes(p) + b"\x00" * ((-len(p)) % 8)

    sections = [(6, padded(code_payload)), (4, padded(consts)), (5, padded(data))]
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
