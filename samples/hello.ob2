module Hello;
import Out;

type Vector = ARRAY 4 OF integer;
type Pair = RECORD a, b: integer END;

var n: integer;
var v: Vector; p: Pair; q: Pair; i: integer;

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
  CountTo(21, n)
end Hello.
