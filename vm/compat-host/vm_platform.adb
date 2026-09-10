--  Host body of VM_Platform: no runtime bookkeeping, just an exit status.
with Ada.Command_Line;

package body VM_Platform is

   procedure Init is
   begin
      null;
   end Init;

   procedure Exit_With (Ok : Boolean) is
   begin
      if Ok then
         Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Success);
      else
         Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      end if;
   end Exit_With;

end VM_Platform;
