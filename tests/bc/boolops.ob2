module Boolops;
(*  BOOLEAN `&` and `or`, which had no opcode.

    Both refused in bytecode mode - `&` with "'&' is not yet supported" and
    `or` with "BOOLEAN operators are not yet supported" - while the spec had
    reserved 0x72-0x7F for exactly this, right beside BEQ/BNE/BTEST.  They take
    the first two of that block (BAND, BOR); nothing is renumbered, and a
    BOOLEAN operation now sits with the other BOOLEAN operations.

    Every case below is a value, and the last one crosses the two fixes: `not`
    is emitted as `= 0` (that was the earlier silent-image work) and `&` is the
    new opcode, so `not (a & b)` fails unless both are right.  The pairs are
    chosen so no case can pass by accident: a false `and`, a true `and`, a true
    `or`, a false `or`, and both under a `not`. *)
import Out;
var a, b, c: boolean;
begin
   a := true;  b := false;  c := true;

   if a & b then Out.Int(0, 0) else Out.Int(1, 0) end; Out.Ln;   (* 1 *)
   if a & c then Out.Int(2, 0) else Out.Int(0, 0) end; Out.Ln;   (* 2 *)
   if a or b then Out.Int(3, 0) else Out.Int(0, 0) end; Out.Ln;  (* 3 *)
   if b or b then Out.Int(0, 0) else Out.Int(4, 0) end; Out.Ln;  (* 4 *)
   if not (a & b) then Out.Int(5, 0) else Out.Int(0, 0) end; Out.Ln;  (* 5 *)
   if not (a or c) then Out.Int(0, 0) else Out.Int(6, 0) end; Out.Ln;  (* 6 *)

   (* both operators in one expression, left to right *)
   if (a or b) & (b or c) then Out.Int(7, 0) else Out.Int(0, 0) end;
   Out.Ln                                                              (* 7 *)
end Boolops.
