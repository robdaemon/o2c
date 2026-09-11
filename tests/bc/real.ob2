module Rea;
import Out;
var x: real; b: boolean;
begin
  b := (x < 1.0);
  if b then Out.Int(42, 0) else Out.Int(0, 0) end;
  Out.Ln;
  b := (x > 1.0);
  if b then Out.Int(9, 0) else Out.Int(42, 0) end;
  Out.Ln
end Rea.
