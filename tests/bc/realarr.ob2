module RealArr;
import Out;
type Vec = array 4 of real;
var v: Vec;
    x: real;
begin
  x := 2.5;
  v[1] := x;
  v[3] := x;
  Out.Real(v[1], 0); Out.Ln;
  Out.Real(v[3], 0); Out.Ln
end RealArr.
