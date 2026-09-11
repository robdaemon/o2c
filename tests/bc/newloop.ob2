module Newloop;
import Out;
type Node = record v: integer; next: Node end;
type P = pointer to Node;
var cur: P; i: integer;
begin
  (* A NEW inside a loop.  NEW's argument used to leave the pointer's old
     value on the operand stack - one slot per execution - so this climbed to
     the stack ceiling and failed as a depth violation at the 256th
     allocation.  500 iterations crosses that twice over. *)
  for i := 1 to 500 do
    NEW(cur);
    cur^.v := i
  end;
  Out.Int(cur^.v, 0);
  Out.Ln
end Newloop.
