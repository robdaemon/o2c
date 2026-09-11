module Rea;
import Out;
var x: real; b: boolean;
begin
  x := 1.5 + 2.5;
  b := (x = 4.0);
  if b then Out.Int(42, 0) else Out.Int(0, 0) end;
  Out.Ln;
  x := x - 1.0;
  b := (x = 3.0);
  if b then Out.Int(42, 0) else Out.Int(1, 0) end;
  Out.Ln;
  b := (x > 1.0);
  if b then Out.Int(42, 0) else Out.Int(2, 0) end;
  Out.Ln
end Rea.
