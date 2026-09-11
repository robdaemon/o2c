module TypeGuard;
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
  Out.Int(a(Pt).v, 0);
  Out.Int(b(Pt3).w, 0);
  Out.Ln
end TypeGuard.
