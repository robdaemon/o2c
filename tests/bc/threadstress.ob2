module TStress;
import Out;
var counter: integer;
    m: integer;
    h0: integer;
    h1: integer;
    h2: integer;
    h3: integer;
procedure Worker;
var k: integer;
begin
  k := 0;
  while k < 5 do
    Threads.Lock(m);
    counter := counter + 1;
    Threads.Unlock(m);
    k := k + 1
  end
end Worker;
begin
  Threads.Init(m);
  counter := 0;
  h0 := Threads.Start(Worker);
  h1 := Threads.Start(Worker);
  h2 := Threads.Start(Worker);
  h3 := Threads.Start(Worker);
  Threads.Join(h0);
  Threads.Join(h1);
  Threads.Join(h2);
  Threads.Join(h3);
  Out.Int(counter, 0); Out.Ln
end TStress.
