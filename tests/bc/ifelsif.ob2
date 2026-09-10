module IfElse;
import Out;
var n: integer;
begin
  n := 7;
  if n < 5 then
    Out.Int(1, 0)
  elsif n < 10 then
    Out.Int(2, 0)
  else
    Out.Int(3, 0)
  end;
  Out.Ln
end IfElse.
