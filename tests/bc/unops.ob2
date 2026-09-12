module Unops;
(*  Unary operators, which bytecode used to drop.

    `not` / `~` and unary `-` were Ada-text-only: the bytecode backend
    emitted NO opcode for either, so the program compiled, ran, and
    stored the unnegated / un-inverted operand.  Both were silent -
    there was no refusal and no diagnostic, just a wrong number, which
    is the one failure mode this backend exists to make impossible.

    Every value below is what the language says it is, so a regression
    reads as a wrong NUMBER rather than as a compile error; a golden
    file is the only thing that can tell those apart. *)
import Out;
var x, y, i, acc: integer; r, q: real; f, g: boolean;
begin
   y := 7;     x := -y;        Out.Int(x, 0);  Out.Ln;   (* -7   *)
   r := 2.5;   q := -r;        Out.Real(q, 0); Out.Ln;   (* -2.500 *)
   Out.Int(-42, 0);  Out.Ln;                             (* -42  folded literal *)
   Out.Real(-2.5, 0); Out.Ln;                            (* -2.500 *)
   x := +y;            Out.Int(x, 0);  Out.Ln;           (* 7    unary + is identity *)

   f := true;
   if not f then Out.Int(1, 0) else Out.Int(0, 0) end; Out.Ln;  (* 0 *)
   if ~f   then Out.Int(1, 0) else Out.Int(0, 0) end; Out.Ln;  (* 0   tilde spelling *)

   f := false;   g := not f;
   if g then Out.Int(9, 0) else Out.Int(0, 0) end; Out.Ln;      (* 9 *)

   g := not (y > 100);
   if g then Out.Int(5, 0) else Out.Int(0, 0) end; Out.Ln;      (* 5   NOT of a comparison *)

   x := -(y + 3);      Out.Int(x, 0);  Out.Ln;           (* -10  NOT a bare operand *)

   acc := 0;
   for i := -2 to 2 do acc := acc + i end;
   Out.Int(acc, 0); Out.Ln                               (* 0    negated FOR bound *)
end Unops.
