--  File input for the bytecode VM.
--
--  Kept as its own unit so obc_vm.adb - the interpreter - owns no file
--  I/O.  One implementation serves both platforms: Ada.Sequential_IO is
--  available in the Aegir runtime as well as on the host (see the body).
--  Only the program lifecycle differs per platform, and that is
--  VM_Platform.
package VM_IO is

   type Byte is mod 256;
   type Byte_Array is array (Natural range <>) of Byte;

   type Status is
     (Ok,
      No_File,      --  missing, unreadable, or not a file
      Too_Big,      --  larger than the caller's buffer
      Read_Error);  --  opened, but a read failed short

   --  Read all of Path into Data, setting Len to the byte count.  Data's
   --  length is the cap; a larger file reports Too_Big rather than being
   --  silently truncated.
   procedure Read_File (Path : String; Data : out Byte_Array;
                        Len : out Natural; St : out Status);

end VM_IO;
