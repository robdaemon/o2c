module Gclive;
import Out;
type Node = record v: integer; next: Node end;
type P = pointer to Node;
var head, cur: P; i, sum: integer;
begin
  (* Every node stays reachable from head, so no collection can reclaim
     anything: 4000 nodes of three slots each is more than the arena holds.
     The VM must say so rather than corrupt itself - which is exactly what it
     did before the collector was fixed, silently freeing the live list. *)
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
end Gclive.
