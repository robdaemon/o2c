module Hello;
import Out;

type Vector = array 4 of integer;
type Pair = record a, b: integer end;
type Line = array 8 of char;
type Node = pointer to NodeDesc;
type NodeDesc = record v: integer; next: Node end;
type Shape = record x: integer end;
type Circle = record (Shape) r: integer end;
type PShape = pointer to Shape;
type PCircle = pointer to Circle;
type Mat = array 2 of Vector;
type Tote = record m: Mat; k: integer end;

var n: integer;
var v: Vector; p: Pair; q: Pair; i: integer;
var msg: Line; ch: char;
var head, cur: Node;
var shp: PShape; circ: PCircle;
var sac: Tote;
var s2: set; l2: longint;

const Greeting = "hello from Oberon-2";

procedure CountTo(k: integer; var total: integer);
begin
  total := 0;
  while total < k * 2 do
    total := total + 1
  end;
  if total = k * 2 then
    Out.Int(total, 0);
    Out.Ln
  else
    Out.Int(0, 0);
    Out.Ln
  end
end CountTo;

procedure Square(x: integer): integer;
begin
  return x * x
end Square;

procedure UpTo12;
  const Goal = 12;
  var k: integer;
begin
  k := 9;
  loop
    k := k + 1;
    if k = Goal then exit end
  end;
  Out.Int(k, 0);
  Out.Ln
end UpTo12;

procedure Dot;
  type Pt = pointer to Point;
  type Point = record x, y: integer end;
  var q: Pt; d: integer;
begin
  new(q);
  q^.x := 3;
  q^.y := 4;
  d := q^.x + q^.y;
  Out.Int(d, 0);
  Out.Ln
end Dot;

procedure Push(var l: Node; v: integer);
  var n: Node;
begin
  new(n);
  n^.v := v;
  n^.next := l;
  l := n
end Push;

procedure SwapPair(var r: Pair);
  var t: integer;
begin
  t := r.a;
  r.a := r.b;
  r.b := t
end SwapPair;

procedure Last(l: Node): Node;
  var r: Node;
begin
  r := l;
  if r # nil then
    while r^.next # nil do
      r := r^.next
    end
  end;
  return r
end Last;

procedure Sum(l: Node): integer;
  var r: Node; t: integer;
begin
  r := l;
  t := 0;
  while r # nil do
    t := t + r^.v;
    r := r^.next
  end;
  return t
end Sum;

procedure FillArr(var a: array of integer; start: integer);
  var j: integer;
begin
  for j := 0 to len(a) - 1 do
    a[j] := start + j
  end
end FillArr;

procedure SumArr(a: array of integer): integer;
  var j, t: integer;
begin
  t := 0;
  for j := 0 to len(a) - 1 do
    t := t + a[j]
  end;
  return t
end SumArr;

procedure CLen(s: array of char): integer;
begin
  return len(s)
end CLen;

procedure (var s: Shape) Widen (k: integer);
begin
  s.x := s.x + k
end Widen;

procedure (var c: Circle) Widen (k: integer);
begin
  c.r := c.r + k
end Widen;

procedure (var c: Circle) Ring: integer;
begin
  return c.r
end Ring;


begin
  n := 0;
  repeat
    n := n + 1;
    Out.Int(n, 0)
  until n = 3;
  Out.Ln;
  Out.String(Greeting);
  Out.Ln;
  for n := 4 to 5 do
    Out.Int(n, 0)
  end;
  Out.Ln;

  Out.Int(Square(3), 0);
  Out.Ln;
  i := 0;
  while i < 4 do
    v[i] := i * i;
    i := i + 1
  end;
  i := 0;
  repeat
    Out.Int(v[i], 0);
    i := i + 1
  until i = 4;
  Out.Ln;
  p.a := 7;
  p.b := Square(p.a) - 1;
  Out.Int(p.b, 0);
  Out.Ln;
  q := p;
  Out.Int(q.b, 0);
  Out.Ln;
  SwapPair(p);
  Out.Int(p.a, 0);
  Out.Ln;
  Out.Int(p.b, 0);
  Out.Ln;
  msg := "hi";
  msg[0] := "H";
  Out.String(msg);
  Out.Ln;
  ch := msg[0];
  if ch = "H" then
    Out.Int(7, 0);
    Out.Ln
  end
  i := 2;
  case i of
    0: Out.Int(0, 0)
  | 1: Out.String("one")
  | 2, 3: Out.Int(i, 0)
  else
    Out.Int(9, 0)
  end;
  Out.Ln
  CountTo(21, n);
  head := nil;
  Push(head, 1);
  Push(head, 2);
  Push(head, 3);
  cur := Last(head);
  Out.Int(head^.v, 0);
  Out.Ln;
  Out.Int(cur^.v, 0);
  Out.Ln;
  Out.Int(Sum(head), 0);
  Out.Ln;
  FillArr(v, 5);
  Out.Int(SumArr(v), 0);
  Out.Ln;
  Out.Int(len(v), 0);
  Out.Ln;
  Out.Int(CLen(msg), 0);
  Out.Ln;
  UpTo12;
  Dot;
  new(shp);
  shp^.x := 0;
  new(circ);
  circ^.x := 10;
  circ^.r := 1;
  shp.Widen(7);
  Out.Int(shp^.x, 0);
  Out.Ln;
  circ.Widen(4);
  Out.Int(circ^.r, 0);
  Out.Ln;
  if circ IS Circle then
    with circ: Circle do
      circ^.r := circ^.r + 2
    end;
    Out.Int(circ^.r, 0);
    Out.Ln
  end;
  shp := circ;
  shp.Widen(3);
  Out.Int(circ.Ring(), 0);
  Out.Ln;
  sac.m[0][1] := 3;
  sac.m[1][2] := 4;
  sac.k := 5;
  Out.Int(sac.m[0][1] + sac.m[1][2] + sac.k, 0);
  Out.Ln;
  s2 := {2, 4, 6};
  if 4 IN s2 then Out.Int(4, 0); Out.Ln end;
  s2 := s2 - {6};
  if 6 IN s2 then Out.Int(0, 0) else Out.Int(6, 0) end;
  Out.Ln;
  l2 := 0;
  while l2 < 60 do
    l2 := l2 + 1
  end;
  if l2 = 60 then Out.Int(1, 0) else Out.Int(0, 0) end;
  Out.Ln
end Hello.
