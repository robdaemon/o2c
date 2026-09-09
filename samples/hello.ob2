module Hello;
import Out;

type Vector = array 4 of integer;
type Pair = record a, b: integer end;
type Line = array 8 of char;
type Node = pointer to NodeDesc;
type NodeDesc = record v: integer; next: Node end;

var n: integer;
var v: Vector; p: Pair; q: Pair; i: integer;
var msg: Line; ch: char;
var head, cur: Node; s: integer;

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
  Out.Ln
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
  new(head);
  head^.v := 1;
  head^.next := nil;
  new(cur);
  cur^.v := 2;
  cur^.next := head;
  head := cur;
  new(cur);
  cur^.v := 3;
  cur^.next := head;
  head := cur;
  cur := head;
  s := 0;
  while cur # nil do
    s := s + cur^.v;
    cur := cur^.next
  end;
  Out.Int(s, 0);
  Out.Ln;
  UpTo12;
  Dot
end Hello.
