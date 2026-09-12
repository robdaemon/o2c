module PtCall;
import Out;
type Body = PROCEDURE;
var b: Body;
procedure Worker;
begin
  Out.Int(1, 0); Out.Ln
end Worker;
begin
  b := Worker;
  b()
end PtCall.
