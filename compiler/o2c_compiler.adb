with Ada.Strings.Unbounded;
with O2c_Lexer;

package body O2c_Compiler is

   use Ada.Strings.Unbounded;
   use type O2c_Lexer.Token_Kind;

   package Lex renames O2c_Lexer;

   Decl_Buf  : Unbounded_String;   --  Ada declarative items (consts, procs)
   Body_Buf  : Unbounded_String;   --  Ada statements of the module body
   Cur       : Lex.Token;
   Mod_Name  : Unbounded_String;
   Used_Int  : Boolean := False;   --  Out.Int used -> emit O2c_Put_Int

   procedure Append_Decl (S : String) is
   begin
      Decl_Buf := Decl_Buf & S & ASCII.LF;
   end Append_Decl;

   procedure Append_Body (S : String) is
   begin
      Body_Buf := Body_Buf & S & ASCII.LF;
   end Append_Body;

   procedure Next is
   begin
      Cur := Lex.Next_Token;
      if Cur.Kind = Lex.Tok_Error then
         raise O2c_Error with "lex error at line "
           & Natural'Image (Cur.Line) & " col " & Natural'Image (Cur.Col)
           & ": '" & Cur.Text (1 .. Cur.Len) & "'";
      end if;
   end Next;

   procedure Expect (K : Lex.Token_Kind; What : String) is
   begin
      if Cur.Kind /= K then
         raise O2c_Error with "expected " & What & " at line "
           & Natural'Image (Cur.Line) & " col " & Natural'Image (Cur.Col)
           & ", found " & Lex.Image (Cur.Kind) & " '" & Cur.Text (1 .. Cur.Len)
           & "'";
      end if;
   end Expect;

   function Ident_Text return String is
   begin
      Expect (Lex.Tok_Ident, "an identifier");
      return Cur.Text (1 .. Cur.Len);
   end Ident_Text;

   function Ada_String_Literal (S : String) return String is
      R : Unbounded_String;
   begin
      R := R & """";
      for I in S'Range loop
         if S (I) = '"' then
            R := R & """""";
         else
            R := R & S (I);
         end if;
      end loop;
      return To_String (R) & """";
   end Ada_String_Literal;

   --  CONST name = <number | -number | "string"> ;
   procedure Decl_Const is
      Name : constant String := Ident_Text;
   begin
      Next;                                     --  past name
      Expect (Lex.Tok_Equal, "'='");
      Next;
      if Cur.Kind = Lex.Tok_Number then
         Append_Decl ("   " & Name & " : constant Integer := "
                      & Cur.Text (1 .. Cur.Len) & ";");
         Next;
      elsif Cur.Kind = Lex.Tok_Minus then
         Next;
         Expect (Lex.Tok_Number, "a number after '-'");
         Append_Decl ("   " & Name & " : constant Integer := -"
                      & Cur.Text (1 .. Cur.Len) & ";");
         Next;
      elsif Cur.Kind = Lex.Tok_String then
         Append_Decl ("   " & Name & " : constant String := "
                      & Ada_String_Literal (Cur.Text (1 .. Cur.Len)) & ";");
         Next;
      else
         raise O2c_Error with "M1 const value must be a number or string"
           & " at line " & Natural'Image (Cur.Line);
      end if;
      Expect (Lex.Tok_Semi, "';'");
      Next;
   end Decl_Const;

   procedure Statement_Seq is
      Head : Unbounded_String;
      Member : String (1 .. 256);
      M_Len  : Natural := 0;
      Arg    : Unbounded_String;
   begin
      loop
         exit when Cur.Kind = Lex.Tok_End or else Cur.Kind = Lex.Tok_EOF;

         if Cur.Kind = Lex.Tok_Ident then
            Head := To_Unbounded_String (Cur.Text (1 .. Cur.Len));
            Next;

            if Cur.Kind = Lex.Tok_Dot then
               Next;
               Expect (Lex.Tok_Ident, "a member name after '.'");
               M_Len := Cur.Len;
               Member (1 .. M_Len) := Cur.Text (1 .. M_Len);
               Next;

               if To_String (Head) /= "Out" then
                  raise O2c_Error with "M1 calls only module Out (found '"
                    & To_String (Head) & "." & Member (1 .. M_Len) & "')";
               end if;

               if M_Len = 2 and then Member (1 .. 2) = "Ln" then
                  Append_Body ("      Aegir_User.Console.Put_Line ("""");");
               else
                  Expect (Lex.Tok_LParen, "'(' after Out." & Member (1 .. M_Len));
                  Next;
                  if (M_Len = 6 and then Member (1 .. 6) = "String")
                    or else (M_Len = 3 and then Member (1 .. 3) = "Int")
                  then
                     if Cur.Kind = Lex.Tok_String then
                        Arg := To_Unbounded_String
                          (Ada_String_Literal (Cur.Text (1 .. Cur.Len)));
                        Next;
                     elsif Cur.Kind = Lex.Tok_Number then
                        Arg := To_Unbounded_String (Cur.Text (1 .. Cur.Len));
                        Next;
                     elsif Cur.Kind = Lex.Tok_Minus then
                        Arg := To_Unbounded_String ("-");
                        Next;
                        Expect (Lex.Tok_Number, "a number after '-'");
                        Arg := Arg & Cur.Text (1 .. Cur.Len);
                        Next;
                     elsif Cur.Kind = Lex.Tok_Ident then
                        Arg := To_Unbounded_String (Cur.Text (1 .. Cur.Len));
                        Next;
                     else
                        raise O2c_Error with "bad argument to Out."
                          & Member (1 .. M_Len) & " at line "
                          & Natural'Image (Cur.Line);
                     end if;
                     if Cur.Kind = Lex.Tok_Comma then
                        Next;                   --  optional width: ignored M1
                        Expect (Lex.Tok_Number, "a width");
                        Next;
                     end if;
                     Expect (Lex.Tok_RParen, "')'");
                     Next;

                     if M_Len = 6 then         --  Out.String
                        Append_Body ("      Aegir_User.Console.Put ("
                                     & To_String (Arg) & ");");
                     else                      --  Out.Int
                        Used_Int := True;
                        Append_Body ("      O2c_Put_Int (" & To_String (Arg)
                                     & ");");
                     end if;
                  else
                     raise O2c_Error with "M1 supports Out.String/Out.Int/"
                       & "Out.Ln only (found Out." & Member (1 .. M_Len) & ")";
                  end if;
               end if;
            else
               --  Call of a local (module-level) procedure: no
               --  arguments in M1.
               Append_Body ("      " & To_String (Head) & ";");
            end if;
         else
            raise O2c_Error with "M1 statements are calls only (line "
              & Natural'Image (Cur.Line) & ")";
         end if;

         if Cur.Kind = Lex.Tok_Semi then
            Next;
         end if;
      end loop;
   end Statement_Seq;

   procedure Decl_Procedure is
      Name : constant String := Ident_Text;
   begin
      Next;
      Expect (Lex.Tok_Semi, "';' after the procedure name");
      Next;

      Append_Decl ("   procedure " & Name & " is");
      Append_Decl ("   begin");
      Statement_Seq;                 --  stops at END
      Expect (Lex.Tok_End, "'END'");
      Next;
      Expect (Lex.Tok_Ident, "the name after END");
      if Cur.Text (1 .. Cur.Len) /= Name then
         raise O2c_Error with "END names '" & Cur.Text (1 .. Cur.Len)
           & "' but PROCEDURE was " & Name;
      end if;
      Next;
      Expect (Lex.Tok_Semi, "';' after END");
      Next;
      Append_Decl ("   end " & Name & ";");
   end Decl_Procedure;

   function Compile (Source : String) return String is
      S : Unbounded_String;
   begin
      Decl_Buf := Null_Unbounded_String;
      Body_Buf := Null_Unbounded_String;
      Mod_Name := Null_Unbounded_String;
      Used_Int := False;

      Lex.Init (Source);
      Next;

      Expect (Lex.Tok_Module, "'MODULE'");
      Next;
      Mod_Name := To_Unbounded_String (Ident_Text);
      Next;
      Expect (Lex.Tok_Semi, "';' after the module name");
      Next;

      --  imports (M1: Out)
      if Cur.Kind = Lex.Tok_Import then
         Next;
         Expect (Lex.Tok_Ident, "an imported module name");
         if Cur.Text (1 .. Cur.Len) /= "Out" then
            raise O2c_Error with "M1 imports only Out (found '"
              & Cur.Text (1 .. Cur.Len) & "')";
         end if;
         Next;
         while Cur.Kind = Lex.Tok_Comma loop
            Next;
            Expect (Lex.Tok_Ident, "an imported module name");
            raise O2c_Error with "M1 imports only Out";
         end loop;
         Expect (Lex.Tok_Semi, "';'");
         Next;
      end if;

      --  declarations (M1: CONST and PROCEDURE, no args/vars/types)
      loop
         exit when Cur.Kind = Lex.Tok_Begin or else Cur.Kind = Lex.Tok_End;
         if Cur.Kind = Lex.Tok_Const then
            Next;
            while Cur.Kind = Lex.Tok_Ident loop
               Decl_Const;
            end loop;
         elsif Cur.Kind = Lex.Tok_Procedure then
            Next;
            Decl_Procedure;
         elsif Cur.Kind = Lex.Tok_Var or else Cur.Kind = Lex.Tok_Type
           or else Cur.Kind = Lex.Tok_Array or else Cur.Kind = Lex.Tok_Record
         then
            raise O2c_Error with Lex.Image (Cur.Kind)
              & " declarations are not in the M1 subset (line "
              & Natural'Image (Cur.Line) & ")";
         else
            raise O2c_Error with "expected CONST/PROCEDURE/BEGIN/END at line "
              & Natural'Image (Cur.Line);
         end if;
      end loop;

      --  statements
      if Cur.Kind = Lex.Tok_Begin then
         Next;
         Statement_Seq;
      end if;

      Expect (Lex.Tok_End, "'END'");
      Next;
      Expect (Lex.Tok_Ident, "the module name after END");
      if Cur.Text (1 .. Cur.Len) /= To_String (Mod_Name) then
         raise O2c_Error with "END names '" & Cur.Text (1 .. Cur.Len)
           & "' but MODULE is " & To_String (Mod_Name);
      end if;
      Next;
      Expect (Lex.Tok_Dot, "'.' after END");
      Next;
      Expect (Lex.Tok_EOF, "end of file");

      --  assemble the Ada program
      S := S & "with Aegir_User.Console;" & ASCII.LF;
      S := S & ASCII.LF;
      S := S & "procedure " & To_String (Mod_Name) & " is" & ASCII.LF;
      if Used_Int then
         S := S & "   procedure O2c_Put_Int (V : Integer) is" & ASCII.LF
           & "      Img : constant String := Integer'Image (V);" & ASCII.LF
           & "   begin" & ASCII.LF
           & "      if Img (Img'First) = ' ' then" & ASCII.LF
           & "         Aegir_User.Console.Put (Img (Img'First + 1 .. Img'Last));"
           & ASCII.LF
           & "      else" & ASCII.LF
           & "         Aegir_User.Console.Put (Img);" & ASCII.LF
           & "      end if;" & ASCII.LF
           & "   end O2c_Put_Int;" & ASCII.LF;
      end if;
      S := S & To_String (Decl_Buf);
      S := S & "begin" & ASCII.LF;
      S := S & "   Aegir_User.Console.Set_Endpoint (1);" & ASCII.LF;
      S := S & To_String (Body_Buf);
      S := S & "end " & To_String (Mod_Name) & ";" & ASCII.LF;
      return To_String (S);
   end Compile;

end O2c_Compiler;
