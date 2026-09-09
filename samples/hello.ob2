module Hello;
import Out;

type Vector = ARRAY 4 OF integer;
type Pair = RECORD a, b: integer END;
type Line = ARRAY 8 OF char;
type Node = POINTER TO NodeDesc;
type NodeDesc = RECORD v: integer; next: Node END;

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
  head := NIL;
  NEW(head);
  head^.v := 1;
  head^.next := NIL;
  NEW(cur);
  cur^.v := 2;
  cur^.next := head;
  head := cur;
  NEW(cur);
  cur^.v := 3;
  cur^.next := head;
  head := cur;
  cur := head;
  s := 0;
  while cur # NIL do
    s := s + cur^.v;
    cur := cur^.next
  end;
  Out.Int(s, 0);
  Out.Ln
end Hello.
