module InlineArr;
import Out;
var v: array 4 of integer;
    s: array 8 of char;
    f: array 8 of boolean;
    b: boolean;
begin
  v[1] := 42;
  Out.Int(v[1], 0); Out.Ln;
  s := "hi";
  Out.String(s); Out.Ln;
  b := TRUE;
  f[3] := b;
  if f[3] then Out.String("yes") else Out.String("no") end; Out.Ln
end InlineArr.
