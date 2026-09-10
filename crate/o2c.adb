with Aegir_User.Console;
with Aegir_User.CLI;
with Ada.Exceptions;
with Ada.Text_IO;
with Ada.Strings.Unbounded;  use Ada.Strings.Unbounded;
with O2c_Compiler;

--  o2c entry point (M19).  Reads the staged demo module sources from
--  the initrd (Tests/O2cLib/Hello.ob2, Tests/O2cLib/Geom.ob2) and
--  compiles them as separate modules; prints every generated Ada unit
--  between markers, so a test boot can capture the files exactly:
--
--      --- unit <file> ---
--      O2C| ...
--      --- unit end ---
--      ...
--      --- ada end ---
procedure O2c is

   Demo_Main : constant String :=
    "RD0:Tests/O2cLib/Hello.ob2";

   function Read_Module (Name : String) return String is
      use Ada.Text_IO;
      F   : File_Type;
      Buf : Unbounded_String;
   begin
      --  CLI.Resolve_Path keeps qualified names (with ':') unchanged;
      --  RD0: is the initrd boot volume, which is where the samples
      --  are staged.
      Open (F, In_File, Aegir_User.CLI.Resolve_Path (Name));
      while not End_Of_File (F) loop
         Buf := Buf & Get_Line (F) & ASCII.LF;
      end loop;
      Close (F);
      return To_String (Buf);
   exception
      when Ada.Text_IO.Name_Error =>
         raise O2c_Compiler.O2c_Error with "cannot open " & Name;
   end Read_Module;

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

   Libs  : O2c_Compiler.Lib_Array;
   Res   : O2c_Compiler.Unit_Array;
   Count : Natural;
   N_Libs : constant Natural := 2;

begin
   Aegir_User.Console.Set_Endpoint (1);
   Aegir_User.Console.Put_Line ("o2c 0.3 (Oberon-2 to Ada for Aegir)");
   Aegir_User.CLI.Init;
   Libs (1) := (Name => To_Unbounded_String ("Geom"),
                Text => To_Unbounded_String
                  (Read_Module ("RD0:Tests/O2cLib/Geom.ob2")));
   Libs (2) := (Name => To_Unbounded_String ("Geo"),
                Text => To_Unbounded_String
                  (Read_Module ("RD0:Tests/O2cLib/Geo.ob2")));
   Res := O2c_Compiler.Compile_Multi
     (Main_Source => Read_Module (Demo_Main), Libs => Libs,
      N_Libs => N_Libs, Count => Count);
   for I in 1 .. Count loop
      Aegir_User.Console.Put_Line ("--- unit "
                                   & To_String (Res (I).File) & " ---");
      Emit_Gen (To_String (Res (I).Text));
      Aegir_User.Console.Put_Line ("--- unit end ---");
   end loop;
   Aegir_User.Console.Put_Line ("--- ada end ---");
exception
   when E : O2c_Compiler.O2c_Error =>
      Aegir_User.Console.Put_Line
        ("o2c error: " & Ada.Exceptions.Exception_Message (E));
      Aegir_User.Console.Put_Line ("--- ada end ---");
end O2c;
