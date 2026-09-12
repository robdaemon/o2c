module TId;
import Out;
procedure Worker;
begin
  Out.Int(Threads.Id(), 0); Out.Ln
end Worker;
begin
  Out.Int(Threads.Id(), 0); Out.Ln;
  Threads.Start(Worker);
  Threads.Yield()
end TId.
