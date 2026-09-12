module ConstFold;
import Out;
const A = 4;
      B = A + 1;
      C = 2 + 3 * 4;
      D = (2 + 3) * 4;
      E = 7 DIV 2;
      F = 7 MOD 2;
begin
  Out.Int(A, 0); Out.Ln;
  Out.Int(B, 0); Out.Ln;
  Out.Int(C, 0); Out.Ln;
  Out.Int(D, 0); Out.Ln;
  Out.Int(E, 0); Out.Ln;
  Out.Int(F, 0); Out.Ln
end ConstFold.
