module NewT;
import Out;
type Pt = record v: integer end;
type P = pointer to Pt;
var q: P;
begin
  NEW(q);
  q^.v := 42;
  Out.Int(q^.v, 0); Out.Ln
end NewT.
