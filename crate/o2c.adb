with Aegir_User.Console;
with Aegir_User.CLI;
with Ada.Exceptions;
with Aegir_User.Files;
with Aegir_User.Syscalls;
with OBC_VM;
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

   use type Aegir_User.Syscalls.U64;   --  for the file-server status compares

   Empty_Libs : constant O2c_Compiler.Lib_Array := (others => <>);
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

   --  M53: compile a slice-sized program to bytecode and write the image, so
   --  the VM (Tests/Vm, program 42) can run something *this guest* built.
   --  After the demo pass on purpose: Compile_Multi's provided-module table
   --  is package state, and a second call must not be the one that emits the
   --  builtin units the capture asserts on.
   begin
      O2c_Compiler.Bytecode_Requested := True;
      Res := O2c_Compiler.Compile_Multi
        (Main_Source => Read_Module ("RD0:Tests/O2cLib/VmGreet.ob2"),
         Libs => Empty_Libs, N_Libs => 0, Count => Count);
      O2c_Compiler.Bytecode_Requested := False;
      declare
         Img : constant String := O2c_Compiler.Bytecode_Image;
         St  : OBC_VM.Status;
      begin
         if Img'Length = 0 then
            raise O2c_Compiler.O2c_Error with "no bytecode image produced";
         end if;
         Aegir_User.Console.Put_Line
           ("o2c bytecode: image" & Natural'Image (Img'Length) & " bytes");
         --  Execute it right here.  The VM is embedded (see o2c.gpr), so the
         --  guest needs no intermediate file: writing one ran into the
         --  writable volume's limits and into a race with the compiler's own
         --  spawn, and neither belongs in the test of "can this guest compile
         --  and run bytecode".  What the image prints is the VM's own Out.*
         --  natives, i.e. real bytecode execution.
         St := OBC_VM.Run_Image (Img);
         Aegir_User.Console.Put_Line
           ("o2c bytecode: vm " & OBC_VM.Image (St));

         --  Also write the image to the writable volume, so the standalone
         --  VM (Tests/Vm, program 42) can run it: a guest compiling a
         --  program and a separate VM executing it is the real shape of the
         --  system, and running it in-process only proves the interpreter.
         --
         --  Through Aegir_User.Files, not Ada.Sequential_IO: o2c is an
         --  Aegir program, the fs protocol creates a file on its first
         --  Write (one call creates *and* fills), and the Oberon Files
         --  module - which the demo exercises every boot - is this same
         --  interface.  Going through the libc layer added a second,
         --  separately-broken create path for no benefit.
         --
         --  No wait here on purpose: the aegir Manifest carries
         --  `await BD0:` between System/Bfs and the programs that need the
         --  volume, so init holds the manifest until the file server knows
         --  the volume and this write cannot race the mount.  A client-side
         --  poll used to stand here; it belonged in the launcher, which
         --  already has the order (see docs/RESUME.md).
         --
         --  Publish atomically: write a temp file, then rename it over the
         --  target.  Writing the target directly does not work - the VM runs
         --  concurrently and has no way to know the writer is finished, so it
         --  opens a half-written image ('truncated or inconsistent' with no
         --  bug in either program).  The rename makes the image appear
         --  complete or not at all; the VM's own retry covers the not-yet.
         declare
            St      : Aegir_User.Syscalls.U64;
            DSt     : Aegir_User.Syscalls.U64;
            Written : Aegir_User.Syscalls.U64;
         begin
            St := Aegir_User.Files.Write
              ("BD0:VmGreet.tmp", 0, Img (Img'First)'Address,
               Aegir_User.Syscalls.U64 (Img'Length), Written);
            --  Keep the two statuses apart: writing both into one variable
            --  hides which step failed, which is precisely the mistake that
            --  cost a long detour in gloss.  Delete answers Not_Found when
            --  there is nothing to remove, and that is fine.
            if St = Aegir_User.Files.Status_Ok then
               DSt := Aegir_User.Files.Delete ("BD0:VmGreet.obc");
               St := Aegir_User.Files.Rename ("BD0:VmGreet.tmp",
                                              "BD0:VmGreet.obc");
            end if;
            if St = Aegir_User.Files.Status_Ok then
               Aegir_User.Console.Put_Line
                 ("o2c bytecode: published BD0:VmGreet.obc");
            else
               Aegir_User.Console.Put_Line
                 ("o2c bytecode: publish failed, rename status"
                  & Aegir_User.Syscalls.U64'Image (St)
                  & " delete status"
                  & Aegir_User.Syscalls.U64'Image (DSt));
            end if;
         exception
            when E : others =>
               Aegir_User.Console.Put_Line
                 ("o2c bytecode: image write failed: "
                  & Ada.Exceptions.Exception_Message (E));
         end;
      end;
   exception
      when E : others =>
         O2c_Compiler.Bytecode_Requested := False;
         Aegir_User.Console.Put_Line
           ("o2c bytecode error: " & Ada.Exceptions.Exception_Message (E));
   end;
exception
   when E : O2c_Compiler.O2c_Error =>
      Aegir_User.Console.Put_Line
        ("o2c error: " & Ada.Exceptions.Exception_Message (E));
      Aegir_User.Console.Put_Line ("--- ada end ---");
end O2c;
