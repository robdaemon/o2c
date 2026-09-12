--  Host body of VM_Platform: no runtime bookkeeping, just an exit status.
with Ada.Command_Line;
with Ada.Direct_IO;
with Ada.Directories;
with Ada.Text_IO;
with Ada.Environment_Variables;
with Ada.IO_Exceptions;

package body VM_Platform is

   procedure Init is
   begin
      null;
   end Init;

   function Resolve_Path (Path : String) return String is
     (Path);

   function Max_Input_Attempts return Natural is
     (1);

   function Quantum_Override return Natural is
      Name : constant String := "O2C_QUANTUM";
      Raw  : constant String :=
        (if Ada.Environment_Variables.Exists (Name)
         then Ada.Environment_Variables.Value (Name)
         else "");
      N    : Natural := 0;
   begin
      --  Digits only.  A malformed value is ignored rather than guessed at,
      --  because a test harness silently running at a quantum it did not ask
      --  for is worse than one that clearly did not take effect.
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
   begin
      Ada.Directories.Delete_File (Path);
   exception
      when others =>
         --  No status to report, and a missing file is not an error the
         --  dialect can express.
         null;
   end Delete_File;

   procedure Rename_File (From, To : String) is
   begin
      Ada.Directories.Rename (From, To);
   exception
      when others =>
         null;
   end Rename_File;

   --  Positioned file I/O on the host: Direct_IO, so a byte is addressable by
   --  index the way the file server's offset is.  The guest's counterpart is
   --  three lines per function (see compat-aegir) - this side is where the real
   --  work is, and it is why the seam exists rather than one shared body.

   package Char_IO is new Ada.Direct_IO (Character);

   function Stat_File (Path : String) return Long_Integer is
      F : Char_IO.File_Type;
   begin
      Char_IO.Open (F, Char_IO.Inout_File, Path);
      declare
         Sz : constant Long_Integer := Long_Integer (Char_IO.Size (F));
      begin
         Char_IO.Close (F);
         return Sz;
      end;
   exception
      when others =>
         --  Missing, unreadable, or not a file: to the dialect these are one
         --  answer - the sentinel that says "no such file yet", which is what
         --  a program polling for a file is looking for.
         return -1;
   end Stat_File;

   function Read_File (Path : String; Offset : Long_Integer;
                       Buf : out String) return Integer is
      F   : Char_IO.File_Type;
      Idx : Long_Integer := Offset;
   begin
      if Offset < 0 then
         return 1;
      end if;
      Char_IO.Open (F, Char_IO.Inout_File, Path);
      --  One element per call, so an offset past the end ENDS the read rather
      --  than raising: the dialect calls that success with less read.
      for I in Buf'Range loop
         begin
            Char_IO.Read (F, Buf (I), Char_IO.Positive_Count (Idx + 1));
         exception
            when Ada.IO_Exceptions.End_Error =>
               Char_IO.Close (F);
               return 0;
         end;
         Idx := Idx + 1;
      end loop;
      Char_IO.Close (F);
      return 0;
   exception
      when others =>
         return 1;
   end Read_File;

   function Write_File (Path : String; Offset : Long_Integer;
                        Buf : String) return Integer is
      F   : Char_IO.File_Type;
      Idx : Long_Integer := Offset;
   begin
      if Offset < 0 then
         return 1;
      end if;
      begin
         Char_IO.Open (F, Char_IO.Inout_File, Path);
      exception
         when Ada.IO_Exceptions.Name_Error =>
            --  A file that does not exist yet.  Writing one is what creating
            --  it means here - the dialect has no separate create.
            Char_IO.Create (F, Char_IO.Inout_File, Path);
      end;
      --  Direct_IO extends a file one element past its end, so a write beyond
      --  that is padded with NULs first.  The guest's file server extends for
      --  the offset it is given; this is the same effect rather than a refused
      --  write.
      while Long_Integer (Char_IO.Size (F)) < Idx loop
         declare
            Pad : constant Character := ASCII.NUL;
         begin
            Char_IO.Write (F, Pad);
         end;
      end loop;
      for I in Buf'Range loop
         Char_IO.Write (F, Buf (I), Char_IO.Positive_Count (Idx + 1));
         Idx := Idx + 1;
      end loop;
      Char_IO.Close (F);
      return 0;
   exception
      when others =>
         return 1;
   end Write_File;

   function Close_File (Path : String) return Integer is
      pragma Unreferenced (Path);
   begin
      --  Nothing to release: every call above opens by name and closes before
      --  returning, because holding a descriptor per open file would be state
      --  the interpreter does not have.  Success, so the module sees in the
      --  host exactly what it sees in the guest.
      return 0;
   end Close_File;

   function Get_Env (Name : String) return String is
     (if Ada.Environment_Variables.Exists (Name)
      then Ada.Environment_Variables.Value (Name)
      else "");

   procedure Set_Env (Name, Value : String) is
   begin
      Ada.Environment_Variables.Set (Name, Value);
   exception
      when others =>
         null;
   end Set_Env;

   function Arg_Get (N : Natural; Buf : out String) return Integer is
      Count : constant Natural :=
        (if Ada.Command_Line.Argument_Count >= 1
         then Ada.Command_Line.Argument_Count - 1 else 0);
   begin
      if N < 1 or else N > Count then
         return -1;
      end if;
      declare
         A : constant String := Ada.Command_Line.Argument (N + 1);
         L : Natural := 0;
      begin
         for C of A loop
            exit when L = Buf'Last;
            L := L + 1;
            Buf (L) := C;
         end loop;
         return L;
      end;
   end Arg_Get;

   procedure Get_Line (S : out String; L : out Natural; E : out Boolean) is
      Line : String (1 .. S'Length);
   begin
      L := 0;
      E := False;
      if Ada.Text_IO.End_Of_File then
         E := True;
         return;
      end if;
      Ada.Text_IO.Get_Line (Line, L);
      for I in 1 .. L loop
         S (S'First + I - 1) := Line (I);
      end loop;
   exception
      when others =>
         --  An unreadable or exhausted stream is end of input, which is the
         --  only failure the dialect can express.
         L := 0;
         E := True;
   end Get_Line;

   procedure Exit_With (Ok : Boolean) is
   begin
      if Ok then
         Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Success);
      else
         Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      end if;
   end Exit_With;

end VM_Platform;
