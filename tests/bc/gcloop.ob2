module Gcloop;
import Out;
type Node = record v: integer; next: Node end;
type P = pointer to Node;
var head, cur: P; i, sum: integer;
begin
  (* 4000 nodes at three slots each is about 96 KiB through a 64 KiB arena,
     so this can only finish if unreachable nodes are reclaimed.  The most
     recent node stays reachable from head, so the list must survive intact. *)
  head := NIL;
  for i := 1 to 4000 do
    NEW(cur);
    cur^.v := i;
    cur^.next := head;
    head := cur
  end;
  sum := 0;
  cur := head;
  for i := 1 to 4000 do
    sum := sum + cur^.v;
    cur := cur^.next
  end;
  Out.Int(sum, 0);
  Out.Ln
end Gcloop.
