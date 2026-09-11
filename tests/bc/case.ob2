module Cas;
import Out;
var i: integer;
begin
  i := 2;
  case i of
    1: Out.Int(11, 0)
  | 2: Out.Int(42, 0)
  | 3: Out.Int(33, 0)
  else Out.Int(0, 0)
  end;
  Out.Ln
end Cas.
