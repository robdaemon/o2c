module CharStr;
import Out;
type Line = array 8 of char;
var s: Line;
    i: integer;
begin
  s := "hi";
  Out.Char(s[0]); Out.Char(s[1]); Out.Ln;
  (* the bytes after the string must be NUL-terminated *)
  i := 2;
  while i < 8 do
    Out.Int(ORD(s[i]), 0);
    i := i + 1
  end;
  Out.Ln
end CharStr.
