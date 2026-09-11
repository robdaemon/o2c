module TypeTest;
import Out;
type Pt = record v: integer end;
type Pt3 = record (Pt) w: integer end;
type P = pointer to Pt;
type P3 = pointer to Pt3;
var a: P; b: P3;
begin
  NEW(a);
  NEW(b);
  if a IS Pt then Out.Int(1, 0) end;
  if b IS Pt then Out.Int(2, 0) end;
  if b IS Pt3 then Out.Int(3, 0) end;
  if a IS Pt3 then Out.Int(4, 0) end;
  Out.Ln
end TypeTest.
