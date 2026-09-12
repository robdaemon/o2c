--  Host front end for the o2c ADA-TEXT backend: compiles one Oberon-2 module
--  and the builtins it imports, and prints every emitted unit between the
--  markers tests/differential.sh parses.
--
--  The mirror of o2c_bc_host, and it exists for exactly one reason: the
--  differential.  Comparing what the two backends DO needs the Ada side's
--  output, and the Ada side's output is Ada text.  o2c.elf emits the same
--  text inside the guest - that is what run_m1 captures - but nothing
--  host-side could produce it, so the differential would have had to run in
--  QEMU.  It does not: the emitted code's only runtime dependency across the
--  whole corpus is the Aegir console package (three subprograms), which
--  tests/ada_host/ supplies on the host in a few lines.  See the note in
--  tests/differential.sh.
--
--  Written that way on purpose: run_vm.sh pins the set of files that mention
--  the Aegir runtime by name, so that a site reaching into Aegir gets noticed.
--  This tool does not reach into it, and naming the package here would have
--  made the tripwire report a fifth site that is only prose.
with Ada.Command_Line;
with Ada.Exceptions;
with Ada.Strings.Unbounded;  use Ada.Strings.Unbounded;
with Ada.Text_IO;
with O2c_Compiler;

procedure O2c_Ada_Host is
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

   Libs  : O2c_Compiler.Lib_Array := (others => <>);
   Units : O2c_Compiler.Unit_Array;
   Count : Natural;
begin
   if Ada.Command_Line.Argument_Count < 1 then
      Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Error,
                            "usage: o2c_ada_host <source.ob2>");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      return;
   end if;

   Units := O2c_Compiler.Compile_Multi
     (Main_Source => Read_File (Ada.Command_Line.Argument (1)),
      Libs => Libs, N_Libs => 0, Count => Count);

   Ada.Text_IO.Put_Line ("--- ada begin ---");
   for I in 1 .. Count loop
      Ada.Text_IO.Put_Line ("--- unit " & To_String (Units (I).File)
                            & " ---");
      Ada.Text_IO.Put_Line (To_String (Units (I).Text));
      Ada.Text_IO.Put_Line ("--- unit end ---");
   end loop;
   Ada.Text_IO.Put_Line ("--- ada end ---");
exception
   when E : O2c_Compiler.O2c_Error =>
      --  A REFUSAL is a result, not a failure of this tool: the Ada backend
      --  has its own gaps, and the differential records which fixtures they
      --  cost rather than treating them as errors.
      Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Error,
                            "ada refused: "
                            & Ada.Exceptions.Exception_Message (E));
      Ada.Command_Line.Set_Exit_Status (2);
end O2c_Ada_Host;
