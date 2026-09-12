module TsName;
import Out;
procedure Worker;
begin
  Out.Int(2, 0); Out.Ln
end Worker;
begin
  Out.Int(1, 0);
  Threads.Start(Worker)
end TsName.
