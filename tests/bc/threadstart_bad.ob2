module WParam;
procedure Needs(x: integer);
begin
end Needs;
begin
  Threads.Start(Needs)
end WParam.
