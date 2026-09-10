--  The VM's image input, one implementation for both platforms: the Aegir
--  runtime *does* provide Ada.Sequential_IO (it is part of the vendored
--  file-I/O stack in userspace/gnat-rts/gnat_full, and built into adalib
--  alongside s-fileio/s-ficobl/s-crtl; userspace/copy links against
--  Ada.Streams.Stream_IO the same way), so no platform split is needed
--  here.
--
--  What *is* platform-specific is the program lifecycle - CLI.Init and
--  CLI.Exit_With in the guest versus a plain exit status on the host - and
--  that stays in VM_Platform with one body per platform.
with Ada.Sequential_IO;
with VM_Platform;

package body VM_IO is
   package Byte_IO is new Ada.Sequential_IO (Byte);

   procedure Close_If_Open (File : in out Byte_IO.File_Type) is
   begin
      if Byte_IO.Is_Open (File) then
         Byte_IO.Close (File);
      end if;
   exception
      when others =>
         null;
   end Close_If_Open;

   --  Retry delay between attempts (see VM_Platform.Max_Input_Attempts).
   Retry_Delay : constant Duration := 0.1;

   procedure Read_File (Path : String; Data : out Byte_Array;
                        Len : out Natural; St : out Status) is
      File    : Byte_IO.File_Type;
      Limit   : constant Natural := VM_Platform.Max_Input_Attempts;
      Attempt : Natural := 1;
   begin
      Len := 0;
      --  In the guest the image may still be arriving: the compiler and the
      --  VM are separate manifest programs that run concurrently.
      loop
         begin
            Byte_IO.Open (File, Byte_IO.In_File, Path);
            exit;
         exception
            when others =>
               if Attempt >= Limit then
                  St := No_File;
                  return;
               end if;
               Attempt := Attempt + 1;
               delay Retry_Delay;
         end;
      end loop;
      loop
         declare
            B : Byte;
         begin
            Byte_IO.Read (File, B);
            if Len >= Data'Length then
               Close_If_Open (File);
               St := Too_Big;
               return;
            end if;
            Data (Len) := B;
            Len := Len + 1;
         end;
      end loop;
   exception
      when Byte_IO.End_Error =>
         Close_If_Open (File);
         St := Ok;
      when others =>
         Close_If_Open (File);
         Len := 0;
         St := No_File;
   end Read_File;

end VM_IO;
