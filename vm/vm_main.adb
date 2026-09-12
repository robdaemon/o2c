--  vm: run an .obc image (M53).
--
--  One argument names the image.  With no argument it runs a default
--  image, because a program spawned from System/Manifest gets no
--  arguments: that is how the in-guest test runs the VM, on the image o2c
--  itself wrote to BD0: in the same boot.  Once the manifest can pass
--  arguments, the default becomes redundant.
with Ada.Command_Line;
with Ada.Text_IO;
with OBC_VM;
with VM_Platform;

procedure VM_Main is
   use Ada.Command_Line;
   use type OBC_VM.Status;

   Default_Image : constant String := "BD0:VmGreet.obc";
   Path          : constant String :=
     (if Argument_Count >= 1 then Argument (1) else Default_Image);
begin
   VM_Platform.Init;
   OBC_VM.Set_Quantum (VM_Platform.Quantum_Override);
   if Argument_Count > 1 then
      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error, "usage: vm [image.obc]");
      VM_Platform.Exit_With (False);
      return;
   end if;
   declare
      Full : constant String := VM_Platform.Resolve_Path (Path);
      St   : OBC_VM.Status;
   begin
      --  On STDERR: the VM's stdout is the interpreted program's output and
      --  nothing else, so anything of the VM's own (this line, diagnostics)
      --  goes to the diagnostics stream.  Still one write, so a concurrent
      --  writer cannot split it.
      Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Error, "vm: running " & Full);
      St := OBC_VM.Run (Full);
      if St = OBC_VM.Ok then
         VM_Platform.Exit_With (True);
      else
         Ada.Text_IO.Put_Line
           (Ada.Text_IO.Standard_Error, "vm: " & OBC_VM.Image (St));
         VM_Platform.Exit_With (False);
      end if;
   end;
end VM_Main;
