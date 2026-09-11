module Ext;
import Out;
type Base = record a: integer end;
type Child = record (Base) b: integer end;
var c: Child; n: integer;
begin
  c.a := 11;
  c.b := 22;
  n := 99;
  Out.Int(c.a, 0);
  Out.Int(c.b, 0);
  Out.Int(n, 0);
  Out.Ln
end Ext.
