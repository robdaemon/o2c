module Deepcall;
import Out;
procedure Down(k: integer): integer;
begin
  if k = 0 then
    return 0
  elsif k > 0 then
    return 1 + Down(k - 1)
  end;
  return -1
end Down;
begin
  Out.Int(Down(500), 0); Out.Ln
end Deepcall.
