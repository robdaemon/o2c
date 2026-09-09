module Math;
const Pi* = 3.14159;
type Point* = record x*, y*: integer; tag: integer end;
type Vec* = array 4 of integer;
type Node* = pointer to NodeDesc;
type NodeDesc* = record v*: integer; next*: Node end;
var base: integer;
var count*: integer;
var origin*: Point;
var marks*: set;
procedure SumArr*(a: array of integer): integer;
  var j: integer; t: integer;
begin
  t := 0;
  for j := 0 to len(a) - 1 do
    t := t + a[j]
  end;
  return t
end SumArr;
procedure Fill*(var v: Vec; start: integer);
  var j: integer;
begin
  for j := 0 to 3 do
    v[j] := start + j
  end
end Fill;
procedure Translate*(var p: Point; dx: integer; dy: integer);
begin
  p.x := p.x + dx;
  p.y := p.y + dy
end Translate;
procedure Next*(l: Node): Node;
begin
  return l^.next
end Next;
procedure (var p: Point) Scale*(k: integer);
begin
  p.x := p.x * k;
  p.y := p.y * k
end Scale;
procedure (var p: Point) Sum*: integer;
begin
  return p.x + p.y
end Sum;
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
