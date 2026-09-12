module TjJoin;
import Out;
var h: integer;
procedure Worker;
begin
  Out.Int(2, 0); Out.Ln
end Worker;
begin
  Out.Int(1, 0); Out.Ln;
  Threads.Start(Worker);
  h := 1;
  Threads.Join(h);
  Out.Int(3, 0); Out.Ln
end TjJoin.
