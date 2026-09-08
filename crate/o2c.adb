with Ada.Text_IO;

--  o2c entry point.  M1: prints version and, once the compiler core
--  lands, compiles an Oberon-2 source path to Ada on stdout.
procedure O2c is
begin
   Ada.Text_IO.Put_Line ("o2c 0.1 (Oberon-2 to Ada for Aegir)");
end O2c;
