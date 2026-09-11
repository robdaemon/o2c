module Proc;
import Out;

procedure Add(x: integer; y: integer);
begin
  Out.Int(x + y, 0); Out.Ln
end Add;

begin
  Add(40, 2)
end Proc.
