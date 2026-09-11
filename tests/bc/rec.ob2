module Rec;
import Out;
type Pt = record x: integer; y: integer end;
var p: Pt;
begin
  p.y := 42;
  Out.Int(p.y, 0); Out.Ln
end Rec.
