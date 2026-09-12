module LocalBody;
import Out;
type Body = PROCEDURE;
procedure Worker;
begin
  Out.Int(2, 0); Out.Ln
end Worker;
procedure Caller;
var b: Body;
begin
  b := Worker;
  Out.Int(1, 0); Out.Ln;
  b();
  Threads.Start(b)
end Caller;
begin
  Caller
end LocalBody.
