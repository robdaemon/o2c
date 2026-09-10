module Sum;
import Out;
var i, sum: integer;
begin
  Out.String("bc slice ok");
  Out.Ln;
  i := 1;
  sum := 0;
  while i <= 28 do
    sum := sum + i;
    i := i + 1
  end;
  Out.Int(sum, 0);
  Out.Ln
end Sum.
