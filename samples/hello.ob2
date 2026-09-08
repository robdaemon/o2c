module Hello;
import Out;

var n: integer;

const Greeting = "hello from Oberon-2";

procedure CountTo(k: integer; var total: integer);
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
