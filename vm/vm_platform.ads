--  Program lifecycle for the VM driver.
--
--  Same seam idea as VM_IO: the spec is shared, the body is per platform.
--  The host build just sets an exit status; the Aegir build must call
--  CLI.Init (args-page redirection trailer, cwd resolution) and exit
--  through CLI.Exit_With, which is what makes output compose with the
--  shell's redirection and pipes.
package VM_Platform is

   --  Called once before anything else.
   procedure Init;

   --  Terminate the process, reporting success or failure.
   procedure Exit_With (Ok : Boolean);

end VM_Platform;
