module TsVar;
import Out;
type Body = PROCEDURE;
var b: Body;
procedure Worker;
begin
  Out.Int(2, 0); Out.Ln
end Worker;
begin
  Out.Int(1, 0);
  b := Worker;
  Threads.Start(b)
end TsVar.
