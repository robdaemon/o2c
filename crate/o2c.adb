with Aegir_User.Console;
with O2c_Lexer;

--  o2c entry point (M1).  Prints the banner, then lexes the sample
--  module and shows the token stream — the case-insensitive-keyword
--  behavior is visible: lowercase module/import/begin/end lex as
--  keywords while identifiers keep their spelling.
procedure O2c is
   use type O2c_Lexer.Token_Kind;

   Sample : constant String :=
     "module Hello;" & ASCII.LF &
     "import Out;" & ASCII.LF &
     ASCII.LF &
     "begin" & ASCII.LF &
     "  Out.String(""hello from Oberon-2"");" & ASCII.LF &
     "  Out.Ln" & ASCII.LF &
     "end Hello.";

   function Text_Of (T : O2c_Lexer.Token) return String is
   begin
      return T.Text (1 .. T.Len);
   end Text_Of;

begin
   Aegir_User.Console.Set_Endpoint (1);
   Aegir_User.Console.Put_Line ("o2c 0.1 (Oberon-2 to Ada for Aegir)");

   O2c_Lexer.Init (Sample);
   loop
      declare
         T : constant O2c_Lexer.Token := O2c_Lexer.Next_Token;
      begin
         exit when T.Kind = O2c_Lexer.Tok_EOF;
         if T.Kind = O2c_Lexer.Tok_Error then
            Aegir_User.Console.Put_Line
              ("lex error at line "
               & Natural'Image (T.Line) & " col "
               & Natural'Image (T.Col) & ": " & Text_Of (T));
            exit;
         end if;
         Aegir_User.Console.Put_Line
           (O2c_Lexer.Image (T.Kind) & " " & Text_Of (T));
      end;
   end loop;
   Aegir_User.Console.Put_Line ("lexed ok");
end O2c;
