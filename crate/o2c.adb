with Aegir_User.Console;

--  o2c entry point.  M1: prints the version banner; the compiler
--  core (lexer/parser/emitter) then reads an Oberon-2 source path
--  and writes generated Ada.  Console output goes through the
--  console Send cap at handle 1 (Set_Endpoint), which works both
--  when init spawns this as Tests/O2c and from the shell.
procedure O2c is
begin
   Aegir_User.Console.Set_Endpoint (1);
   Aegir_User.Console.Put_Line ("o2c 0.1 (Oberon-2 to Ada for Aegir)");
end O2c;
