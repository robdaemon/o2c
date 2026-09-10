--  Aegir body of VM_Platform: CLI.Init parses the args page (redirection
--  trailer, cwd) and CLI.Exit_With closes the redirects, so the VM's
--  output behaves like every other CLI program's.
with Aegir_User.CLI;

package body VM_Platform is

   procedure Init is
   begin
      Aegir_User.CLI.Init;
   end Init;

   function Resolve_Path (Path : String) return String is
   begin
      return Aegir_User.CLI.Resolve_Path (Path);
   end Resolve_Path;

   function Max_Input_Attempts return Natural is
     (100);   --  100 x 100 ms in VM_IO: the compiler may still be writing

   procedure Exit_With (Ok : Boolean) is
   begin
      if Ok then
         Aegir_User.CLI.Exit_With (Aegir_User.CLI.RC_Ok);
      else
         Aegir_User.CLI.Exit_With (Aegir_User.CLI.RC_Fail);
      end if;
   end Exit_With;

end VM_Platform;
