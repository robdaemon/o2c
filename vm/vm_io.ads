--  File input for the bytecode VM.
--
--  The spec is shared; only the body differs, chosen by the project's
--  source directories, because the two platforms read files very
--  differently: the host build has Ada.Sequential_IO, while the Aegir
--  runtime has neither Sequential_IO nor Ada.Streams and must go through
--  Aegir_User.Files (which reads into a caller buffer at an offset).
--
--      vm/compat-host/vm_io.adb    Ada.Sequential_IO     (make vm-host)
--      vm/compat-aegir/vm_io.adb   Aegir_User.Files      (make vm-aegir)
--
--  Keeping this seam explicit means obc_vm.adb - the interpreter, which
--  is where the real logic lives - is platform-independent.
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
