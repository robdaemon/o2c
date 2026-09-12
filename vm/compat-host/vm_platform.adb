--  Host body of VM_Platform: no runtime bookkeeping, just an exit status.
with Ada.Command_Line;
with Ada.Directories;
with Ada.Environment_Variables;

package body VM_Platform is

   procedure Init is
   begin
      null;
   end Init;

   function Resolve_Path (Path : String) return String is
     (Path);

   function Max_Input_Attempts return Natural is
     (1);

   function Quantum_Override return Natural is
      Name : constant String := "O2C_QUANTUM";
      Raw  : constant String :=
        (if Ada.Environment_Variables.Exists (Name)
         then Ada.Environment_Variables.Value (Name)
         else "");
      N    : Natural := 0;
   begin
      --  Digits only.  A malformed value is ignored rather than guessed at,
      --  because a test harness silently running at a quantum it did not ask
      --  for is worse than one that clearly did not take effect.
      if Raw'Length = 0 then
         return 0;
      end if;
      for C of Raw loop
         if C not in '0' .. '9' then
            return 0;
         end if;
      end loop;
      N := Natural'Value (Raw);
      return N;
   end Quantum_Override;

   procedure Delete_File (Path : String) is
   begin
      Ada.Directories.Delete_File (Path);
   exception
      when others =>
         --  No status to report, and a missing file is not an error the
         --  dialect can express.
         null;
   end Delete_File;

   procedure Rename_File (From, To : String) is
   begin
      Ada.Directories.Rename (From, To);
   exception
      when others =>
         null;
   end Rename_File;

   procedure Exit_With (Ok : Boolean) is
   begin
      if Ok then
         Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Success);
      else
         Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      end if;
   end Exit_With;

end VM_Platform;
