module Longarith;
(*  LONGINT arithmetic, which was refused wholesale.

    Assignment and comparison worked; every operator refused with "bytecode
    backend: LONGINT is not yet supported".  That was a precaution rather than
    a limitation: a LONGINT is the same 8-byte slot as an INTEGER in this VM,
    so the integer opcode IS the LONGINT opcode - no conversion, no second
    opcode - and the same is true for the unary sign and for MOD, whose guard
    was worded "needs INTEGER operands".

    The existing longint.ob2 only ever assigned and compared, so no test could
    have noticed; the value here is that each operator is checked for its
    RESULT, not for compiling.

    The last case is the point of a LONGINT: 1e9 * 3 = 3e9 does not fit in 32
    bits, so a slot that had been quietly narrowed anywhere would print
    WIDE-BAD.  (Its own literals are small on purpose - a LONGINT literal above
    INTEGER'Last is still refused, which is a separate gap recorded in
    tests/bytecode_gaps.sh.) *)
import Out;
var n: longint;
begin
   n := 6;
   n := n + 1;
   if n = 7 then Out.String("add") else Out.String("ADD-BAD") end; Out.Ln;

   n := n - 3;
   if n = 4 then Out.String("sub") else Out.String("SUB-BAD") end; Out.Ln;

   n := n * 5;
   if n = 20 then Out.String("mul") else Out.String("MUL-BAD") end; Out.Ln;

   n := n DIV 6;
   if n = 3 then Out.String("div") else Out.String("DIV-BAD") end; Out.Ln;

   n := n MOD 2;
   if n = 1 then Out.String("mod") else Out.String("MOD-BAD") end; Out.Ln;

   n := -n;
   if n = -1 then Out.String("neg") else Out.String("NEG-BAD") end; Out.Ln;

   n := 1000000000;
   n := n * 3;
   if n DIV 1000000000 = 3 then Out.String("wide") else Out.String("WIDE-BAD") end;
   Out.Ln
end Longarith.
