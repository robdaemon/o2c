--  Host body of VM_IO: plain Ada file I/O (the Aegir body lives in
--  ../compat-aegir and is selected by the Aegir project).
with Ada.Sequential_IO;

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

   procedure Read_File (Path : String; Data : out Byte_Array;
                        Len : out Natural; St : out Status) is
      File : Byte_IO.File_Type;
   begin
      Len := 0;
      Byte_IO.Open (File, Byte_IO.In_File, Path);
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
