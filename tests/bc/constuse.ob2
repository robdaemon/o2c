module ConstUse;
import Out;
const N = 3;
      Big = 4000;
var k: integer;
    i: integer;
begin
  k := N;
  Out.Int(k, 0); Out.Ln;
  i := 0;
  while i < N do
    i := i + 1
  end;
  Out.Int(i, 0); Out.Ln;
  Out.Int(Big + 1, 0); Out.Ln
end ConstUse.
