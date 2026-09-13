module Strconst;
import Out;
const Greeting = "hello from Oberon-2";
const Twice = "again";
begin
  Out.String(Greeting); Out.Ln;
  Out.String(Twice); Out.Char(" "); Out.String(Greeting); Out.Ln
end Strconst.
