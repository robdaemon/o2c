with Aegir_User.Console;
with O2c_Compiler;

--  o2c entry point (M1).  Compiles the embedded hello sample and
--  prints the generated Ada, one prefixed line at a time, between
--  markers.  The 'O2C|' prefix makes host-side reconstruction exact
--  even though the console is shared with concurrent boot chatter.
procedure O2c is

   Sample : constant String :=
     "module Hello;" & ASCII.LF &
     "import Out;" & ASCII.LF &
     ASCII.LF &
     "const Greeting = ""hello from Oberon-2"";" & ASCII.LF &
     ASCII.LF &
     "begin" & ASCII.LF &
     "  Out.String(Greeting);" & ASCII.LF &
     "  Out.Ln" & ASCII.LF &
     "end Hello.";

   Gen : constant String := O2c_Compiler.Compile (Sample);

   procedure Emit_Line (Line : String) is
   begin
      Aegir_User.Console.Put_Line ("O2C|" & Line);
   end Emit_Line;

   procedure Emit_Gen is
      Start : Positive := Gen'First;
      I     : Positive := Gen'First;
   begin
      while I <= Gen'Last loop
         if Gen (I) = ASCII.LF then
            Emit_Line (Gen (Start .. I - 1));
            Start := I + 1;
         end if;
         I := I + 1;
      end loop;
      if Start <= Gen'Last then
         Emit_Line (Gen (Start .. Gen'Last));
      end if;
   end Emit_Gen;

begin
   Aegir_User.Console.Set_Endpoint (1);
   Aegir_User.Console.Put_Line ("o2c 0.1 (Oberon-2 to Ada for Aegir)");
   Aegir_User.Console.Put_Line ("--- ada begin ---");
   Emit_Gen;
   Aegir_User.Console.Put_Line ("--- ada end ---");
end O2c;
