module Arr;
import Out;
type Vec = array 4 of integer;
var a: Vec; i: integer;
begin
  a[2] := 42;
  i := a[2];
  Out.Int(i, 0); Out.Ln
end Arr.
