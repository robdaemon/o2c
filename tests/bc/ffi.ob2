module FFI;
import Convert, Out;
var s: array 8 of char;
    x: integer;
    r: integer;
begin
  s := "42";
  Convert.ToInt(s, x, r);
  Out.Int(x, 0); Out.Ln
end FFI.
