--  Host front end for the o2c bytecode backend (M53).
--
--  Compiles one Oberon-2 module to a .obc image with no Aegir runtime
--  and no QEMU: the compiler core withs only Ada and the lexer, so this
--  builds against the plain host toolchain.  That keeps the emitter
--  testable in seconds while the VM's own Aegir build does not exist
--  yet, and it stays useful afterwards as the fast front end.
--
--  Extra arguments are library module sources, compiled first so the main
--  source can import them.  That is how the built-in FFI modules are reached:
--  a module whose own name is the builtin's carries the FFI primitives, and
--  the main source only calls its exported procedures.
with Ada.Command_Line;
with Ada.Exceptions;
with Ada.Sequential_IO;
with Ada.Strings.Unbounded;  use Ada.Strings.Unbounded;
with Ada.Text_IO;
with O2c_BC;
with O2c_Compiler;

procedure O2c_Bc_Host is
   package Char_IO is new Ada.Sequential_IO (Character);

   function Read_File (Path : String) return String is
      F : Ada.Text_IO.File_Type;
      B : Unbounded_String;
   begin
      Ada.Text_IO.Open (F, Ada.Text_IO.In_File, Path);
      while not Ada.Text_IO.End_Of_File (F) loop
         B := B & Ada.Text_IO.Get_Line (F) & ASCII.LF;
      end loop;
      Ada.Text_IO.Close (F);
      return To_String (B);
   exception
      when Ada.Text_IO.Name_Error =>
         raise O2c_Compiler.O2c_Error with "cannot open " & Path;
   end Read_File;

   Libs   : O2c_Compiler.Lib_Array := (others => <>);
   N_Libs : Natural := 0;
   Count  : Natural;
   Units      : O2c_Compiler.Unit_Array;
   pragma Unreferenced (Units);   --  the Ada text is not this tool's output
begin
   if Ada.Command_Line.Argument_Count < 2 then
      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error,
         "usage: o2c_bc_host <source.ob2> <out.obc> [lib.ob2 ...]");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      return;
   end if;

   for I in 3 .. Ada.Command_Line.Argument_Count loop
      if N_Libs = O2c_Compiler.Max_Libs then
         Ada.Text_IO.Put_Line
           (Ada.Text_IO.Standard_Error,
            "o2c error: too many libraries (limit"
            & Natural'Image (O2c_Compiler.Max_Libs) & ")");
         Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
         return;
      end if;
      N_Libs := N_Libs + 1;
      declare
         Path : constant String := Ada.Command_Line.Argument (I);
      begin
         Libs (N_Libs) :=
           (Name => To_Unbounded_String (Path),
            Text => To_Unbounded_String (Read_File (Path)));
      end;
   end loop;

   O2c_Compiler.Bytecode_Requested := True;
   Units := O2c_Compiler.Compile_Multi
     (Main_Source => Read_File (Ada.Command_Line.Argument (1)),
      Libs        => Libs,
      N_Libs      => N_Libs,
      Count       => Count);

   if Count = 0 then
      raise O2c_Compiler.O2c_Error with "compilation produced no units";
   end if;

   declare
      Img : constant String := O2c_Compiler.Bytecode_Image;
      F   : Char_IO.File_Type;
   begin
      if Img'Length = 0 then
         raise O2c_Compiler.O2c_Error with "no bytecode image produced";
      end if;
      Char_IO.Create (F, Char_IO.Out_File, Ada.Command_Line.Argument (2));
      for C of Img loop
         Char_IO.Write (F, C);
      end loop;
      Char_IO.Close (F);
      Ada.Text_IO.Put_Line ("o2c_bc_host: " & Ada.Command_Line.Argument (2)
                            & " (" & Natural'Image (Img'Length)
                            & " bytes)");
   end;
exception
   when E : O2c_Compiler.O2c_Error =>
      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error,
         "o2c error: " & Ada.Exceptions.Exception_Message (E));
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   when E : O2c_BC.Wrong_Construct =>
      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error,
         "o2c error: " & Ada.Exceptions.Exception_Message (E));
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
end O2c_Bc_Host;
