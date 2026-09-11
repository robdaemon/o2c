module ImpDeref;
import Out;
type Pt = record v: integer end;
type P = pointer to Pt;
var q, r: P;
begin
  NEW(q);
  NEW(r);
  q.v := 42;
  r^.v := q.v;
  Out.Int(q.v, 0);
  Out.Int(r^.v, 0);
  Out.Ln
end ImpDeref.
