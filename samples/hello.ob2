module Hello;
import Out;

var n: INTEGER;

const Greeting = "hello from Oberon-2";

procedure CountTo(k: INTEGER; VAR total: INTEGER);
begin
  total := k * 2;
  Out.Int(total, 0);
  Out.Ln
end CountTo;

begin
  n := 0;
  Out.String(Greeting);
  Out.Ln;
  CountTo(21, n)
end Hello.
