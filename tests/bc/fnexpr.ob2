module FnExpr;
import Out;
var y: integer;
procedure Twice(x: integer): integer;
begin
  return x + x
end Twice;
begin
  y := Twice(21);
  Out.Int(y, 0);
  Out.Int(Twice(0) + Twice(1) + Twice(2), 0);
  Out.Ln
end FnExpr.
