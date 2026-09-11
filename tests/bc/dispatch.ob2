module Dispatch;
import Out;
type Shape = record x: integer end;
type Circle = record (Shape) r: integer end;
type P = pointer to Shape;
type PC = pointer to Circle;
var s: P; c: PC;
procedure (var h: Shape) Which(n: integer): integer;
begin
  return 1
end Which;
procedure (var k: Circle) Which(n: integer): integer;
begin
  return 2
end Which;
begin
  NEW(s);
  NEW(c);
  s.x := 5;
  c.r := 7;
  Out.Int(s.Which(0), 0);
  Out.Int(c.Which(0), 0);
  Out.Ln
end Dispatch.
