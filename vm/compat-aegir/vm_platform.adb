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

   --  Guest wait for the image, in VM_IO's 100 ms steps.  Generous on
   --  purpose: the writer is o2c, a manifest sibling, and it compiles the
   --  whole 12-import demo before reaching its bytecode pass, which takes
   --  minutes on this target.  Giving up early is indistinguishable from a
   --  missing image, so the cap only exists to keep a wedged boot from
   --  hanging forever.
   function Max_Input_Attempts return Natural is
     (3000);   --  300 s

   procedure Exit_With (Ok : Boolean) is
   begin
      if Ok then
         Aegir_User.CLI.Exit_With (Aegir_User.CLI.RC_Ok);
      else
         Aegir_User.CLI.Exit_With (Aegir_User.CLI.RC_Fail);
      end if;
   end Exit_With;

end VM_Platform;
