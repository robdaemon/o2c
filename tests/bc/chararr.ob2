module CharArr;
import Out;
type Line = array 8 of char;
var s: Line;
    a: char;
    b: char;
    c: char;
begin
  a := "a"; b := "b"; c := "z";
  s[0] := a;
  s[1] := b;
  s[5] := c;
  Out.Char(s[0]); Out.Char(s[1]); Out.Char(s[5]); Out.Ln
end CharArr.
