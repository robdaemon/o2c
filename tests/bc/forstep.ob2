module Forstep;
(*  FOR ... BY, the loop step.

    `by` was one of the token kinds with no fixture anywhere - in the corpus
    the backend actually runs.  The step is not read from the operand stack:
    the header parses it, uses its TEXT as a compile-time constant, and then
    Discards the one value that parse pushed.  So `by` exercises a path where
    a stray or missing stack slot is invisible in a golden unless the values
    are asserted - which is what this file does.

    Only ascending loops appear: o2c's FOR takes its direction from whether
    the BY text starts with '-', and `by -1` never reaches the header as a
    negative number (see the coverage check's known-gap entries). *)
import Out;
var i, acc: integer;
begin
   acc := 0;
   for i := 1 to 6 by 2 do acc := acc + i end;
   Out.Int(acc, 0); Out.Ln;      (* 1 + 3 + 5 = 9 *)

   acc := 0;
   for i := 2 to 8 by 3 do acc := acc + i end;
   Out.Int(acc, 0); Out.Ln;      (* 2 + 5 + 8 = 15 *)

   acc := 0;
   for i := 4 to 4 by 5 do acc := acc + 1 end;
   Out.Int(acc, 0); Out.Ln;      (* one pass: 4 <= 4 *)

   acc := 0;
   for i := 0 to 9 by 4 do acc := acc + i end;
   Out.Int(acc, 0); Out.Ln       (* 0 + 4 + 8 = 12 *)
end Forstep.
