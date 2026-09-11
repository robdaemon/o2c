module Nested;
import Out;
type Vec = array 4 of integer;
type Inner = record f: integer end;
type Outer = record n: integer; a: Vec; inner: Inner end;
var o: Outer;
begin
  o.n := 5;
  o.a[0] := 7;
  o.a[3] := 9;
  o.inner.f := 11;
  Out.Int(o.n, 0);
  Out.Int(o.a[0], 0);
  Out.Int(o.a[3], 0);
  Out.Int(o.inner.f, 0);
  Out.Ln
end Nested.
