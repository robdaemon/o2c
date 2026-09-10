module VmGreet;
import Out;
var i, sum: integer;
begin
  Out.String("vm elf ok ");
  i := 1;
  sum := 0;
  while i <= 10 do
    sum := sum + i;
    i := i + 1
  end;
  Out.Int(sum, 0);
  Out.Ln
end VmGreet.
