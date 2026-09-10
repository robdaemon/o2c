--  Aegir body of VM_IO.
--
--  The runtime has no Sequential_IO, Direct_IO or Ada.Streams, so the
--  image is read through the file server: Open (which allocates and maps
--  the read buffer) then Read (Name, Offset, Dest, Length, Count) into
--  the caller's buffer - the pattern userspace/libman uses to stage a
--  file.  Paths are cwd-resolved and fully qualified by CLI.
with Aegir_User.CLI;
with Aegir_User.Files;
with Aegir_User.Syscalls;

package body VM_IO is
   use Aegir_User.Syscalls;
   use type U64;

   Chunk_Max : constant U64 := 65536;

   procedure Read_File (Path : String; Data : out Byte_Array;
                        Len : out Natural; St : out Status) is
      Full  : constant String := Aegir_User.CLI.Resolve_Path (Path);
      Size  : U64;
      Off   : U64 := 0;
      Chunk : U64;
      Count : U64;
      RC    : U64;
   begin
      Len := 0;
      RC := Aegir_User.Files.Open (Full, Size);
      if RC /= Aegir_User.Files.Status_Ok then
         St := No_File;
         return;
      end if;
      if Size > U64 (Data'Length) then
         St := Too_Big;
         return;
      end if;
      while Off < Size loop
         Chunk := U64'Min (Size - Off, Chunk_Max);
         Count := 0;
         RC := Aegir_User.Files.Read
           (Full, Off, Data (Natural (Off))'Address, Chunk, Count);
         if RC /= Aegir_User.Files.Status_Ok or else Count /= Chunk then
            St := Read_Error;
            return;
         end if;
         Off := Off + Chunk;
      end loop;
      Len := Natural (Size);
      St := Ok;
   end Read_File;

end VM_IO;
