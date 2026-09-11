module RecMix;
import Out;
type R = record flag: boolean; ch: char; n: integer end;
var r: R;
begin
  r.n := 7;
  r.ch := "A";
  r.flag := TRUE;
  if r.flag then Out.Int(r.n, 0) end;
  if r.ch = "A" then Out.Int(1, 0) end;
  Out.Ln
end RecMix.
