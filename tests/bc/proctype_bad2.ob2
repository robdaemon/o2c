module ProcTypeBad2;
(* A PROCEDURE-typed target accepts a procedure name, nothing else. *)
type Body = PROCEDURE;
var b: Body;
begin
  b := 5
end ProcTypeBad2.
