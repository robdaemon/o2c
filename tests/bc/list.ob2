module List;
import Out;
type Node = record v: integer; next: Node end;
type P = pointer to Node;
var p, q: P;
begin
  NEW(p);
  NEW(q);
  p^.v := 42;
  q^.next := p;
  if q^.next # NIL then Out.Int(1, 0) end;
  Out.Int(q^.next^.v, 0); Out.Ln
end List.
