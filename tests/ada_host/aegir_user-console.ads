--  Host stand-in for the Aegir console, so the Ada backend's output can be
--  BUILT AND RUN natively.
--
--  Why this is enough.  The differential compares what the two backends do,
--  and the Ada side's output is Ada source.  That source's runtime dependency
--  across the whole corpus is this one package - three subprograms - because
--  the builtin modules are emitted as pure Ada (Convert.ToInt converts a
--  string by hand) and Out is inlined into Console calls.  That was measured,
--  not assumed: `grep -ho 'Aegir_User\.[A-Za-z_.]*'` over the emitted units of
--  every fixture in tests/bc returns only Console.Put, Console.Put_Line and
--  Console.Set_Endpoint.  So the guest toolchain, QEMU and the initrd are not
--  needed for this check, and the differential is a host sweep.
--
--  The One Point That Matters: Put must write WITHOUT a newline and
--  Put_Line ("") must write bare.  The emitted Out.Int is `Console.Put (image)`
--  followed by `Console.Put_Line ("")`, so buffering or auto-terminating here
--  would make the Ada side's output differ from the VM's for reasons that have
--  nothing to do with either backend.
package Aegir_User.Console is

   --  The Aegir console is written to on behalf of a program group.  There is
   --  one writer on the host, so the endpoint is recorded and ignored - but it
   --  is recorded, so that a fixture which sets it twice is not silently a
   --  different program here than in the guest.
   procedure Set_Endpoint (Endpoint : Integer);

   --  Write Text with no terminator.
   procedure Put (Text : String);

   --  Write Text followed by a line break.
   procedure Put_Line (Text : String);

   --  The endpoint a program last selected, for the record above.
   function Endpoint return Integer;

end Aegir_User.Console;
