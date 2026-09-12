module Fordown;
(*  Descending FOR, which could not be written at all.

    Oberon-2 takes the FOR direction from the step's SIGN, so `by -1` is the
    only way to ask for a descent - and it was rejected, because the BY
    header validated the step by scanning its Ada IMAGE for digits: unary
    minus wraps the literal as `-(1)`, and the '(' failed the scan.  (The
    check even allowed a leading '-' on purpose, so it was a bug in the check,
    not a missing feature.)  A second wall stood behind it: the emitter wrote
    the step with a numeric conversion, which RAISES for a negative value, so
    nothing could have encoded a descent even once the parse succeeded.

    Both ends are fixed, and this file is the evidence that the whole path
    agrees - parser, emitter, and the VM's direction handling, which derives
    the direction from from-vs-to and steps by abs (step).

    The ordering matters: every value here is what the language says, and each
    descending case would print a wrong number (not fail) if the step reached
    the opcode as a positive 1 or as zero. *)
import Out;
const STEP = -2;
var i, acc, n: integer;
begin
   (* descending, step -1: 3 + 2 + 1 *)
   acc := 0;
   for i := 3 to 1 by -1 do acc := acc + i end;
   Out.Int(acc, 0); Out.Ln;      (* 6  *)

   (* descending, step -2: 9 + 7 + 5 + 3 + 1 *)
   acc := 0;
   for i := 9 to 1 by -2 do acc := acc + i end;
   Out.Int(acc, 0); Out.Ln;      (* 25 *)

   (* the step may come from a CONST - a negative one, which the old digit
      scan would also have refused, since the name is not digits *)
   acc := 0;
   for i := 5 to 1 by STEP do acc := acc + i end;
   Out.Int(acc, 0); Out.Ln;      (* 9  *)

   (* a bound that is not a literal: 4 + 1 *)
   n := 4;
   acc := 0;
   for i := n to 1 by -3 do acc := acc + i end;
   Out.Int(acc, 0); Out.Ln;      (* 5  *)

   (* ascending is unchanged: 1 + 3 + 5 *)
   acc := 0;
   for i := 1 to 6 by 2 do acc := acc + i end;
   Out.Int(acc, 0); Out.Ln;      (* 9  *)

   (* descending with NO by: the step is +1, so the body runs zero times.
      This is correct Oberon-2 - a descent needs an explicit negative step -
      and it is the case that used to be mistaken for the gap. *)
   acc := 0;
   for i := 3 to 1 do acc := acc + i end;
   Out.Int(acc, 0); Out.Ln;      (* 0  *)

   (* two iterations of a descending loop, counted from inside *)
   acc := 0;
   for i := 10 to 4 by -4 do acc := acc + 1 end;
   Out.Int(acc, 0); Out.Ln       (* 2: i = 10, 6 *)
end Fordown.
