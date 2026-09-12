module BoolArr;
import Out;
type Flags = array 8 of boolean;
var v: Flags;
    a: boolean;
    b: boolean;
begin
  a := TRUE; b := FALSE;
  v[0] := b; v[4] := a; v[7] := a;
  if v[0] then Out.String("t") else Out.String("f") end;
  if v[4] then Out.String("t") else Out.String("f") end;
  if v[7] then Out.String("t") else Out.String("f") end;
  Out.Ln
end BoolArr.
