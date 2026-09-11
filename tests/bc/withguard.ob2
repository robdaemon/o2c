module WithGuard;
import Out;
type Pt = record v: integer end;
type Pt3 = record (Pt) w: integer end;
type P = pointer to Pt;
type P3 = pointer to Pt3;
var a: P; b: P3;
begin
  NEW(a);
  NEW(b);
  a.v := 5;
  b.v := 7;
  b.w := 42;
  WITH b: Pt3 DO Out.Int(b.w, 0) END;
  WITH a: Pt3 DO Out.Int(9, 0) END;
  WITH a: Pt DO Out.Int(a.v, 0) END;
  Out.Ln
end WithGuard.
