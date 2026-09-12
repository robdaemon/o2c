module FFI;
import Convert, Out;
var s: array 8 of char;
    x: integer;
    v: real;
    r: integer;
begin
  s := "42";
  Convert.ToInt(s, x, r);
  Out.Int(x, 0); Out.Ln;
  s := "2.5";
  Convert.ToReal(s, v, r);
  Out.Real(v, 0); Out.Ln;
  x := 1234;
  Convert.FromInt(x, s);
  Out.String(s); Out.Ln
end FFI.
