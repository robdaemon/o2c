module Math;
const Pi* = 3.14159;
type Point* = record x, y: integer end;
type Node* = pointer to NodeDesc;
type NodeDesc* = record v: integer; next: Node end;
var base: integer;
var count*: integer;
procedure Sqr*(x: integer): integer;
begin
  return x * x
end Sqr;
procedure SetBase*(b: integer);
begin
  base := b
end SetBase;
procedure Bump*(var n: integer);
begin
  n := n + base
end Bump;
begin
  base := 10
end Math.
