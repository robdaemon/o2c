module RecReal;
import Out;
type R = record n: integer; re: real end;
var r: R;
begin
  r.n := 3;
  r.re := 0.5;
  Out.Int(r.n, 0);
  Out.Real(r.re, 0);
  Out.Ln
end RecReal.
