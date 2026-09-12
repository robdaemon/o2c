with Ada.Text_IO;

package body Aegir_User.Console is

   Last_Endpoint : Integer := 0;

   procedure Set_Endpoint (Endpoint : Integer) is
   begin
      Last_Endpoint := Endpoint;
   end Set_Endpoint;

   procedure Put (Text : String) is
   begin
      --  No newline, and no buffering: the emitted code splits a number from
      --  its terminator across Put and Put_Line ("") on purpose, and the VM's
      --  Out.Int does the same in one native.
      Ada.Text_IO.Put (Text);
   end Put;

   procedure Put_Line (Text : String) is
   begin
      Ada.Text_IO.Put_Line (Text);
   end Put_Line;

   function Endpoint return Integer is (Last_Endpoint);

end Aegir_User.Console;
