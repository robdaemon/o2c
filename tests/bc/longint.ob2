module LongInt;
import Out;
var n: longint;
    m: longint;
begin
  n := 6;
  m := n;
  if n = 6 then Out.String("assign-ok") else Out.String("assign-bad") end; Out.Ln;
  if m = n then Out.String("copy-ok") else Out.String("copy-bad") end; Out.Ln;
  n := 2;
  if n < 3 then Out.String("lt-ok") else Out.String("lt-bad") end; Out.Ln;
  if n # 3 then Out.String("ne-ok") else Out.String("ne-bad") end; Out.Ln;
  if n > 5 then Out.String("gt-bad") else Out.String("gt-ok") end; Out.Ln
end LongInt.
