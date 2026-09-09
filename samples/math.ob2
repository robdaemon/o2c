module Math;
const Pi* = 3.14159;
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
