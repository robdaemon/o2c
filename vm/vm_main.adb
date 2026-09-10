--  vm: run an .obc image (M53 thin slice).  Host build for now; the
--  Aegir build reuses this driver unchanged.
with Ada.Command_Line;
with Ada.Text_IO;
with OBC_VM;

procedure VM_Main is
   use Ada.Command_Line;
   use type OBC_VM.Status;
begin
   if Argument_Count /= 1 then
      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error, "usage: vm <image.obc>");
      Set_Exit_Status (Failure);
      return;
   end if;
   declare
      St : constant OBC_VM.Status := OBC_VM.Run (Argument (1));
   begin
      if St = OBC_VM.Ok then
         Set_Exit_Status (Success);
      else
         Ada.Text_IO.Put_Line
           (Ada.Text_IO.Standard_Error, "vm: " & OBC_VM.Image (St));
         Set_Exit_Status (Failure);
      end if;
   end;
end VM_Main;
