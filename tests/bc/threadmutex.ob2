module MxSrc;
import Out;
var m: integer;
    h: integer;
procedure Worker;
begin
  Threads.Lock(m);
  Out.Int(2, 0); Out.Ln;
  Threads.Unlock(m)
end Worker;
begin
  Threads.Init(m);
  Out.Int(1, 0); Out.Ln;
  h := Threads.Start(Worker);
  Threads.Join(h);
  Threads.Lock(m);
  Out.Int(3, 0); Out.Ln;
  Threads.Unlock(m)
end MxSrc.
