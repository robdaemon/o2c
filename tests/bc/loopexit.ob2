module Loopexit;
(*  LOOP / EXIT, which bytecode used to drop.

    Parse_Loop and Parse_Exit appended only Ada text, so in bytecode mode
    the body became a STRAIGHT-LINE block that ran once and fell through,
    and EXIT vanished.  `loop i := i + 1 end` - an infinite loop -
    terminated with i = 1, printing a wrong number and saying nothing.

    The two cases that need a real label are here: EXIT from inside a
    nested WHILE must leave the LOOP rather than the WHILE, and a nested
    LOOP's EXIT must leave only the inner one.  If the nested case were
    wrong this program would not print a wrong number - it would never
    terminate, which the suite's timeout catches. *)
import Out;
var i, acc: integer;
begin
   (* EXIT on a condition: 3 passes, two of them adding 10 *)
   i := 0; acc := 0;
   loop
      i := i + 1;
      if i >= 3 then exit end;
      acc := acc + 10
   end;
   Out.Int(i, 0); Out.Ln;      (* 3  *)
   Out.Int(acc, 0); Out.Ln;    (* 20 *)

   (* EXIT immediately: exactly one pass *)
   i := 0;
   loop
      i := i + 1;
      exit
   end;
   Out.Int(i, 0); Out.Ln;      (* 1 *)

   (* Nested LOOP: the inner EXIT leaves only the inner *)
   i := 0; acc := 0;
   loop
      i := i + 1;
      loop
         acc := acc + 1;
         exit
      end;
      if i >= 2 then exit end
   end;
   Out.Int(i, 0); Out.Ln;      (* 2 *)
   Out.Int(acc, 0); Out.Ln;    (* 2 *)

   (* EXIT from inside a nested WHILE leaves the LOOP, not the WHILE.
      Read the acc: the `acc := acc + 1000` after the WHILE must never run,
      and the inner increment runs exactly twice before i reaches 3. *)
   i := 0; acc := 0;
   loop
      i := i + 1;
      while i < 100 do
         if i = 3 then exit end;
         i := i + 1;
         acc := acc + 1
      end;
      acc := acc + 1000
   end;
   Out.Int(i, 0); Out.Ln;      (* 3 *)
   Out.Int(acc, 0); Out.Ln     (* 2 *)
end Loopexit.
