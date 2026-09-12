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

   --  Guest wait for the image, in VM_IO's 100 ms steps.  Effectively
   --  "wait for it": the writer is o2c, a manifest sibling that compiles the
   --  whole 12-import demo before reaching its bytecode pass, and that takes
   --  minutes on this target - every finite guess here has been too small
   --  (10 s, 60 s, 300 s each expired first), and giving up early is
   --  indistinguishable from a missing image.  The wait is cheap: it polls
   --  and returns immediately once the image appears, and the boot itself
   --  bounds a process that would otherwise spin forever.
   function Max_Input_Attempts return Natural is
     (30000);
   --  50 min: longer than any boot

   --  No environment in the guest: the override is a host-test facility.
   function Quantum_Override return Natural is
     (0);

   procedure Exit_With (Ok : Boolean) is
   begin
      if Ok then
         Aegir_User.CLI.Exit_With (Aegir_User.CLI.RC_Ok);
      else
         Aegir_User.CLI.Exit_With (Aegir_User.CLI.RC_Fail);
      end if;
   end Exit_With;

end VM_Platform;
