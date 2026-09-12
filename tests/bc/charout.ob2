module CharOut;
import Out;
type Line = array 16 of char;
var s: Line;
    t: Line;
    u: Line;
begin
  s := "hello";
  t := "a";
  u := "";
  Out.String(s); Out.Ln;
  Out.String(t); Out.Ln;
  Out.String(u); Out.Ln;
  Out.Int(9, 0); Out.Ln
end CharOut.
