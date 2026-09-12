#!/usr/bin/env python3
"""Generate dialect sources for the built-in FFI modules (M51/M52).

One source of truth.  Each module's public procedure has a body that is the
*unqualified primitive* the compiler recognises: while compiling `MODULE X`
an unqualified call to a known name is rewritten into the Ada helper for that
primitive, so the emitted code is not recursive even though the source reads
that way.  `MODULE Convert`'s `ConvToInt` therefore has a body calling
`ConvToInt` - the compiler replaces it with `O2c_Conv_ToInt`.

That is also why these sources must be generated rather than hand-written:
the names, arities and types are the compiler's own knowledge of the modules,
and a hand-written copy would drift from it silently, which is the failure
mode this whole section exists to remove.

Writes samples/<module>.ob2.  The Aegir Makefile copies samples/ into
initrd/root/Tests/O2cLib/, so the guest sees the same files.

Parameter syntax is the dialect's: `array of char`, `integer`, `real`, and
`var` for an out parameter.
"""

import os
import sys

#  module -> [(public name, [(param name, type)], return type or None)]
#  Only names the compiler actually recognises may appear here; an unknown one
#  is refused by the compiler, not silently accepted.
MODULES = {
    "Convert": [
        ("ConvToInt",   [("s", "array of char"),
                         ("base", "integer"),
                         ("n", "var integer")], None),
        ("ConvToReal",  [("s", "array of char"),
                         ("base", "integer"),
                         ("r", "var real")], None),
        ("ConvFromInt", [("n", "integer"),
                         ("s", "var array of char")], None),
    ],
}


def emit_module(name, procs):
    out = ["module %s;" % name]
    for pname, params, ret in procs:
        #  `var` is written before the name (`var p: Point`), not after the
        #  colon - the dialect's convention, visible in samples/geom.ob2.
        def par(pn, pt):
            if pt.startswith("var "):
                return "var %s: %s" % (pn, pt[4:])
            return "%s: %s" % (pn, pt)
        sig = "; ".join(par(pn, pt) for pn, pt in params)
        tail = sig
        #  The header ends with ';' after the closing paren, whether or not
        #  there are local declarations.
        out.append("procedure %s*(%s)%s;" % (pname, tail,
                                             (": %s" % ret) if ret else ""))
        out.append("begin")
        out.append("  %s(%s)%s" % (pname,
                                   ", ".join(pn for pn, _ in params),
                                   ("; return result") if ret else ""))
        out.append("end %s;" % pname)
    out.append("end %s." % name)
    return "\n".join(out) + "\n"


def main():
    outdir = sys.argv[1] if len(sys.argv) > 1 else "samples"
    os.makedirs(outdir, exist_ok=True)
    for name, procs in sorted(MODULES.items()):
        path = os.path.join(outdir, name.lower() + ".ob2")
        text = emit_module(name, procs)
        if os.path.exists(path) and open(path).read() == text:
            print("  %s (unchanged)" % path)
            continue
        open(path, "w").write(text)
        print("  %s" % path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
