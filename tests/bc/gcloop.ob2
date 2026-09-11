module Gcloop;
import Out;
type Node = record v: integer; next: Node end;
type P = pointer to Node;
var head, tail, cur: P; i, sum, live: integer;
begin
  (* A sliding window of 500 nodes.  20000 allocations pass through, so all
     but the last 500 become garbage that the collector must reclaim; the
     arena is far too small to hold them all live.  A collector that frees
     too much corrupts the window and the sum comes out wrong, so this checks
     retention as much as reclamation. *)
  head := NIL;
  tail := NIL;
  live := 0;
  for i := 1 to 20000 do
    NEW(cur);
    cur^.v := i;
    cur^.next := NIL;
    if head = NIL then
      head := cur;
      tail := cur
    else
      tail^.next := cur;
      tail := cur
    end;
    live := live + 1;
    if live > 500 then
      head := head^.next;
      live := live - 1
    end
  end;
  (* The window holds 19501 .. 20000. *)
  sum := 0;
  cur := head;
  for i := 1 to 500 do
    sum := sum + cur^.v;
    cur := cur^.next
  end;
  Out.Int(sum, 0);
  Out.Ln
end Gcloop.
