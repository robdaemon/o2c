module Local;
import Out;

procedure Sum3(x: integer);
var t: integer;
begin
  t := x + 1;
  Out.Int(t, 0); Out.Ln
end Sum3;

begin
  Sum3(41)
end Local.
