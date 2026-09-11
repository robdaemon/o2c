module Ptr;
import Out;
type Pt = record v: integer end;
type P = pointer to Pt;
var q: P;
begin
  q := NIL;
  if q = NIL then Out.Int(1, 0) end;
  Out.Ln
end Ptr.
