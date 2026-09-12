module TjNat;
import Out;
type Body = PROCEDURE;
var h: integer;
    b: Body;
procedure Worker;
begin
  Out.Int(2, 0); Out.Ln
end Worker;
begin
  Out.Int(1, 0); Out.Ln;
  b := Worker;
  h := Threads.Start(b);
  Threads.Join(h);
  Out.Int(3, 0); Out.Ln
end TjNat.
