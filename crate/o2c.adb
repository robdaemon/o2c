with Aegir_User.Console;
with Ada.Exceptions;
with O2c_Compiler;

--  o2c entry point (M2 subset).  Compiles the embedded demo module
--  and prints the generated Ada, one prefixed line at a time, between
--  markers, so a test boot can capture it and the host build can
--  reconstruct the file exactly.
--
--  The demo exercises module vars, a constant expression, an
--  assignment, an expression call argument, and a procedure with a
--  value and a VAR parameter.
procedure O2c is

  Sample : constant String :=
    "module Hello;" & ASCII.LF &
    "import Out;" & ASCII.LF &
    ASCII.LF &
    "var n: integer;" & ASCII.LF &
    ASCII.LF &
    "const Greeting = ""hello from Oberon-2"";" & ASCII.LF &
    ASCII.LF &
    "procedure CountTo(k: integer; var total: integer);" & ASCII.LF &
    "begin" & ASCII.LF &
    "  total := 0;" & ASCII.LF &
    "  while total < k * 2 do" & ASCII.LF &
    "    total := total + 1" & ASCII.LF &
    "  end;" & ASCII.LF &
    "  if total = k * 2 then" & ASCII.LF &
    "    Out.Int(total, 0);" & ASCII.LF &
    "    Out.Ln" & ASCII.LF &
    "  else" & ASCII.LF &
    "    Out.Int(0, 0);" & ASCII.LF &
    "    Out.Ln" & ASCII.LF &
    "  end" & ASCII.LF &
    "end CountTo;" & ASCII.LF &
    "procedure Square(x: integer): integer;" & ASCII.LF &
    "begin" & ASCII.LF &
    "  return x * x" & ASCII.LF &
    "end Square;" & ASCII.LF &
    ASCII.LF &
    "begin" & ASCII.LF &
    "  n := 0;" & ASCII.LF &
    "  repeat" & ASCII.LF &
    "    n := n + 1;" & ASCII.LF &
    "    Out.Int(n, 0)" & ASCII.LF &
    "  until n = 3;" & ASCII.LF &
    "  Out.Ln;" & ASCII.LF &
    "  Out.String(Greeting);" & ASCII.LF &
    "  Out.Ln;" & ASCII.LF &
    "  for n := 4 to 5 do" & ASCII.LF &
    "    Out.Int(n, 0)" & ASCII.LF &
    "  end;" & ASCII.LF &
    "  Out.Ln;" & ASCII.LF &
    "  CountTo(21, n)" & ASCII.LF &
    "end Hello.";


   procedure Emit_Line (Line : String) is
   begin
      Aegir_User.Console.Put_Line ("O2C|" & Line);
   end Emit_Line;

   procedure Emit_Gen (G : String) is
      Start : Positive := G'First;
      I     : Positive := G'First;
   begin
      while I <= G'Last loop
         if G (I) = ASCII.LF then
            Emit_Line (G (Start .. I - 1));
            Start := I + 1;
         end if;
         I := I + 1;
      end loop;
      if Start <= G'Last then
         Emit_Line (G (Start .. G'Last));
      end if;
   end Emit_Gen;

begin
   Aegir_User.Console.Set_Endpoint (1);
   Aegir_User.Console.Put_Line ("o2c 0.2 (Oberon-2 to Ada for Aegir)");
   Aegir_User.Console.Put_Line ("--- ada begin ---");
   declare
      Gen : constant String := O2c_Compiler.Compile (Sample);
   begin
      Emit_Gen (Gen);
   exception
      when E : O2c_Compiler.O2c_Error =>
         Aegir_User.Console.Put_Line
           ("o2c error: " & Ada.Exceptions.Exception_Message (E));
   end;
   Aegir_User.Console.Put_Line ("--- ada end ---");
end O2c;
