--  Token-kind coverage scan.
--
--  Lexes each source given on the command line with the REAL lexer and prints
--  the token kinds that occur, one per line, so a coverage check can compare
--  what the corpus exercises against the language's full token set.
--
--  Why the lexer and not a grep: a grep counts occurrences inside comments,
--  which the lexer never sees, and it cannot tell `>=` from `>` followed by
--  `=`, or `*` inside a `(* *)` from a multiply.  Both failure modes were
--  observed - an earlier corpus grep reported `~` as "covered" because
--  samples/hello.ob2 contains one, although no test ever compiles that file,
--  and `not` was silently wrong in bytecode at the time.  The lexer answers
--  the question that was actually being asked: which constructs does this
--  corpus PUT IN FRONT OF THE BACKEND.
with Ada.Command_Line;
with Ada.Strings.Unbounded;  use Ada.Strings.Unbounded;
with Ada.Text_IO;
with O2c_Lexer;

procedure O2c_Tokscan is
   use type O2c_Lexer.Token_Kind;

   Seen : array (O2c_Lexer.Token_Kind) of Boolean := (others => False);

   function Read_File (Path : String) return String is
      F : Ada.Text_IO.File_Type;
      B : Unbounded_String;
   begin
      Ada.Text_IO.Open (F, Ada.Text_IO.In_File, Path);
      while not Ada.Text_IO.End_Of_File (F) loop
         B := B & Ada.Text_IO.Get_Line (F) & ASCII.LF;
      end loop;
      Ada.Text_IO.Close (F);
      return To_String (B);
   end Read_File;

   procedure Scan (Path : String) is
      T : O2c_Lexer.Token;
   begin
      O2c_Lexer.Init (Read_File (Path));
      loop
         T := O2c_Lexer.Next_Token;
         Seen (T.Kind) := True;
         exit when T.Kind = O2c_Lexer.Tok_EOF;
      end loop;
   end Scan;

begin
   if Ada.Command_Line.Argument_Count = 0 then
      Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Error,
                            "usage: o2c_tokscan <source.ob2> ...");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      return;
   end if;

   for I in 1 .. Ada.Command_Line.Argument_Count loop
      Scan (Ada.Command_Line.Argument (I));
   end loop;

   --  Enum 'Image uppercases the literal, so this prints TOK_NOT and so on.
   for K in O2c_Lexer.Token_Kind'Range loop
      if Seen (K) then
         Ada.Text_IO.Put_Line (O2c_Lexer.Token_Kind'Image (K));
      end if;
   end loop;
end O2c_Tokscan;
