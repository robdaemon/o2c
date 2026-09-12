module ProcType;
(* A procedure type and a procedure value: the value is a procedure id, and
   assigning one is not a variable copy - the right-hand side names a
   procedure rather than reading a slot. *)
type Body = PROCEDURE;
var b: Body;
procedure Worker;
begin
end Worker;
begin
  b := Worker
end ProcType.
