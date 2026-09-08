module Hello;
import Out;

var n: integer;

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
  CountTo(21, n)
end Hello.
