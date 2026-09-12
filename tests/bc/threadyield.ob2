module TYield;
import Out;
procedure Worker;
begin
  Out.Int(2, 0); Out.Ln
end Worker;
begin
  Out.Int(1, 0); Out.Ln;
  Threads.Start(Worker);
  Threads.Yield();
  Out.Int(3, 0); Out.Ln
end TYield.
