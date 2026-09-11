module OpenArr;
import Out;
type Vec4 = array 4 of integer;
type Vec6 = array 6 of integer;
var v4: Vec4; v6: Vec6;
procedure Sum6(a: array of integer): integer;
var i, s: integer;
begin
  s := 0;
  for i := 0 to 5 do s := s + a[i] end;
  return s
end Sum6;
procedure Sum4(a: array of integer): integer;
var i, s: integer;
begin
  s := 0;
  for i := 0 to 3 do s := s + a[i] end;
  return s
end Sum4;
begin
  v4[0] := 1; v4[1] := 2; v4[2] := 3; v4[3] := 4;
  v6[0] := 10; v6[1] := 20; v6[2] := 30;
  v6[3] := 40; v6[4] := 50; v6[5] := 60;
  Out.Int(Sum6(v6), 0);
  Out.Int(Sum4(v4), 0);
  Out.Ln
end OpenArr.
