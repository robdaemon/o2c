--  Aegir body of VM_Platform: CLI.Init parses the args page (redirection
--  trailer, cwd) and CLI.Exit_With closes the redirects, so the VM's
--  output behaves like every other CLI program's.
with Aegir_User.CLI;
with Aegir_User.Files;
with Aegir_Interface;

package body VM_Platform is

   procedure Init is
   begin
      Aegir_User.CLI.Init;
      --  Reached, not merely present: gprbuild builds only the units a main
      --  can reach, so a probe nothing calls is silently never compiled -
      --  which is how the first version of it passed while doing nothing.
      Aegir_Interface.Touch;
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

   --  The guest has an environment too: Aegir keeps variables as ENV:<Name>
   --  files, and M51's Env builtin reads and writes them through this very
   --  call.  So O2C_QUANTUM works here the same way it does on the host, and
   --  the guest test can be driven at a different quantum - which matters,
   --  because the guest is the only place the VM runs on the real target.
   function Quantum_Override return Natural is
      Raw : constant String := Aegir_User.CLI.Get_Env ("O2C_QUANTUM");
      N   : Natural := 0;
   begin
      --  Digits only, as on the host: a malformed value is ignored rather
      --  than guessed at, because a harness silently running at a quantum it
      --  did not ask for is worse than one that visibly did not take effect.
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
      --  The file server's status is dropped on purpose: Oakwood's
      --  Files.Delete has no status to report, so surfacing one here would
      --  invent an API the dialect does not have.  A subsequent Stat is how a
      --  program finds out whether it worked.
      Status : constant Aegir_User.Files.U64 :=
        Aegir_User.Files.Delete (Path);
      pragma Unreferenced (Status);
   begin
      null;
   end Delete_File;

   procedure Exit_With (Ok : Boolean) is
   begin
      if Ok then
         Aegir_User.CLI.Exit_With (Aegir_User.CLI.RC_Ok);
      else
         Aegir_User.CLI.Exit_With (Aegir_User.CLI.RC_Fail);
      end if;
   end Exit_With;

end VM_Platform;
