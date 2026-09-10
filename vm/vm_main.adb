--  vm: run an .obc image (M53).
--
--  One argument names the image.  With no argument it runs a default
--  image, because a program spawned from System/Manifest gets no
--  arguments: that is how the in-guest test runs the VM (the fixture the
--  aegir build stages at Tests/O2cBC/VmGreet.obc).  Once the manifest can
--  pass arguments, the default becomes redundant.
with Ada.Command_Line;
with Ada.Text_IO;
with OBC_VM;
with VM_Platform;

procedure VM_Main is
   use Ada.Command_Line;
   use type OBC_VM.Status;

   Default_Image : constant String := "RD0:Tests/O2cBC/VmGreet.obc";
   Path          : constant String :=
     (if Argument_Count >= 1 then Argument (1) else Default_Image);
begin
   VM_Platform.Init;
   if Argument_Count > 1 then
      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error, "usage: vm [image.obc]");
      VM_Platform.Exit_With (False);
      return;
   end if;
   declare
      St : constant OBC_VM.Status :=
        OBC_VM.Run (VM_Platform.Resolve_Path (Path));
   begin
      if St = OBC_VM.Ok then
         VM_Platform.Exit_With (True);
      else
         Ada.Text_IO.Put_Line
           (Ada.Text_IO.Standard_Error, "vm: " & OBC_VM.Image (St));
         VM_Platform.Exit_With (False);
      end if;
   end;
end VM_Main;
