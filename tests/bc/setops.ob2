module SetOps;
import Out;
var a: set;
    b: set;
    c: set;
    d: boolean;
begin
  a := {1, 2}; b := {2, 3};
  c := a + b;
  d := 1 in c; if d then Out.String("u1 ") else Out.String("U1 ") end;
  d := 3 in c; if d then Out.String("u3") else Out.String("U3") end; Out.Ln;
  c := a * b;
  d := 2 in c; if d then Out.String("i2 ") else Out.String("I2 ") end;
  d := 1 in c; if d then Out.String("I1") else Out.String("i1") end; Out.Ln;
  c := a - b;
  d := 1 in c; if d then Out.String("d1 ") else Out.String("D1 ") end;
  d := 2 in c; if d then Out.String("D2") else Out.String("d2") end; Out.Ln;
  c := a / b;
  d := 2 in c; if d then Out.String("X2 ") else Out.String("x2 ") end;
  d := 1 in c; if d then Out.String("x1") else Out.String("X1") end; Out.Ln
end SetOps.
