module Rep;
import Out;
var i: integer;
begin
  i := 0;
  repeat
    i := i + 1
  until i = 42;
  Out.Int(i, 0); Out.Ln
end Rep.
