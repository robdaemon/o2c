package body O2c_Lexer is

   Src : String (1 .. 1_000_000) := (others => ' ');
   Len : Natural := 0;
   Pos : Natural := 0;
   Cur_Line : Positive := 1;
   Cur_Col  : Positive := 1;

   function Fold_Upper (C : Character) return Character is
   begin
      if C in 'a' .. 'z' then
         return Character'Val (Character'Pos (C) - 32);
      end if;
      return C;
   end Fold_Upper;

   procedure Init (Source : String) is
   begin
      Len := Source'Length;
      if Len > Src'Length then
         Len := Src'Length;
      end if;
      for I in 1 .. Len loop
         Src (I) := Source (Source'First - 1 + I);
      end loop;
      Pos := 0;
      Cur_Line := 1;
      Cur_Col := 1;
   end Init;

   procedure Advance (Count : Positive := 1) is
   begin
      for I in 1 .. Count loop
         if Pos < Len then
            Pos := Pos + 1;
            if Src (Pos) = ASCII.LF then
               Cur_Line := Cur_Line + 1;
               Cur_Col := 1;
            else
               Cur_Col := Cur_Col + 1;
            end if;
         end if;
      end loop;
   end Advance;

   function Peek return Character is
   begin
      if Pos < Len then
         return Src (Pos + 1);
      end if;
      return ASCII.NUL;
   end Peek;

   function Image (Kind : Token_Kind) return String is
   begin
      case Kind is
         when Tok_EOF       => return "EOF";
         when Tok_Error     => return "error";
         when Tok_Ident     => return "ident";
         when Tok_Number    => return "number";
         when Tok_String    => return "string";
         when Tok_Module    => return "keyword MODULE";
         when Tok_Import    => return "keyword IMPORT";
         when Tok_Begin     => return "keyword BEGIN";
         when Tok_End       => return "keyword END";
         when Tok_Const     => return "keyword CONST";
         when Tok_Var       => return "keyword VAR";
         when Tok_Procedure => return "keyword PROCEDURE";
         when Tok_Type      => return "keyword TYPE";
         when Tok_Array     => return "keyword ARRAY";
         when Tok_Of        => return "keyword OF";
         when Tok_Record    => return "keyword RECORD";
         when Tok_Pointer   => return "keyword POINTER";
         when Tok_Case      => return "keyword CASE";
         when Tok_If        => return "keyword IF";
         when Tok_Then      => return "keyword THEN";
         when Tok_Elsif     => return "keyword ELSIF";
         when Tok_Else      => return "keyword ELSE";
         when Tok_While     => return "keyword WHILE";
         when Tok_Do        => return "keyword DO";
         when Tok_Repeat    => return "keyword REPEAT";
         when Tok_Until     => return "keyword UNTIL";
         when Tok_For       => return "keyword FOR";
         when Tok_To        => return "keyword TO";
         when Tok_By        => return "keyword BY";
         when Tok_Loop      => return "keyword LOOP";
         when Tok_Exit      => return "keyword EXIT";
         when Tok_Return    => return "keyword RETURN";
         when Tok_True      => return "keyword TRUE";
         when Tok_False     => return "keyword FALSE";
         when Tok_Nil       => return "keyword NIL";
         when Tok_Is        => return "keyword IS";
         when Tok_With      => return "keyword WITH";
         when Tok_In        => return "keyword IN";
         when Tok_Div       => return "keyword DIV";
         when Tok_Mod       => return "keyword MOD";
         when Tok_And       => return "keyword AND";
         when Tok_Or        => return "keyword OR";
         when Tok_Not       => return "keyword NOT";
         when Tok_Semi      => return "symbol ;";
         when Tok_Colon     => return "symbol :";
         when Tok_Assign    => return "symbol :=";
         when Tok_Dot       => return "symbol .";
         when Tok_Comma     => return "symbol ,";
         when Tok_LParen    => return "symbol (";
         when Tok_RParen    => return "symbol )";
         when Tok_LBracket  => return "symbol [";
         when Tok_RBracket  => return "symbol ]";
         when Tok_LBrace    => return "symbol {";
         when Tok_RBrace    => return "symbol }";
         when Tok_Plus      => return "symbol +";
         when Tok_Minus     => return "symbol -";
         when Tok_Star      => return "symbol *";
         when Tok_Slash     => return "symbol /";
         when Tok_Equal     => return "symbol =";
         when Tok_NE        => return "symbol #";
         when Tok_LT        => return "symbol <";
         when Tok_LE        => return "symbol <=";
         when Tok_GT        => return "symbol >";
         when Tok_GE        => return "symbol >=";
         when Tok_Tilde     => return "symbol ~";
         when Tok_Amp       => return "symbol &";
         when Tok_Bar       => return "symbol |";
         when Tok_Caret     => return "symbol ^";
      end case;
   end Image;

   function Keyword_Of (Word : String) return Token_Kind is
      Folded : String (1 .. Word'Length);
   begin
      for I in Word'Range loop
         Folded (I - Word'First + 1) := Fold_Upper (Word (I));
      end loop;

      if Folded = "MODULE" then return Tok_Module;
      elsif Folded = "IMPORT" then return Tok_Import;
      elsif Folded = "BEGIN" then return Tok_Begin;
      elsif Folded = "END" then return Tok_End;
      elsif Folded = "CONST" then return Tok_Const;
      elsif Folded = "VAR" then return Tok_Var;
      elsif Folded = "PROCEDURE" then return Tok_Procedure;
      elsif Folded = "TYPE" then return Tok_Type;
      elsif Folded = "ARRAY" then return Tok_Array;
      elsif Folded = "OF" then return Tok_Of;
      elsif Folded = "RECORD" then return Tok_Record;
      elsif Folded = "POINTER" then return Tok_Pointer;
      elsif Folded = "CASE" then return Tok_Case;
      elsif Folded = "IF" then return Tok_If;
      elsif Folded = "THEN" then return Tok_Then;
      elsif Folded = "ELSIF" then return Tok_Elsif;
      elsif Folded = "ELSE" then return Tok_Else;
      elsif Folded = "WHILE" then return Tok_While;
      elsif Folded = "DO" then return Tok_Do;
      elsif Folded = "REPEAT" then return Tok_Repeat;
      elsif Folded = "UNTIL" then return Tok_Until;
      elsif Folded = "FOR" then return Tok_For;
      elsif Folded = "TO" then return Tok_To;
      elsif Folded = "BY" then return Tok_By;
      elsif Folded = "LOOP" then return Tok_Loop;
      elsif Folded = "EXIT" then return Tok_Exit;
      elsif Folded = "RETURN" then return Tok_Return;
      elsif Folded = "TRUE" then return Tok_True;
      elsif Folded = "FALSE" then return Tok_False;
      elsif Folded = "NIL" then return Tok_Nil;
      elsif Folded = "IS" then return Tok_Is;
      elsif Folded = "WITH" then return Tok_With;
      elsif Folded = "IN" then
         --  M45: the Oakwood basic module is named `In`.  Keywords
         --  are case-insensitive here (project deviation), but the
         --  exact spelling `In` (capital I, lowercase n) is reserved
         --  as that module name; `IN`/`in` remain the membership
         --  keyword.
         if Word = "In" then
            return Tok_Ident;
         end if;
         return Tok_In;
      elsif Folded = "DIV" then return Tok_Div;
      elsif Folded = "MOD" then return Tok_Mod;
      elsif Folded = "AND" then return Tok_And;
      elsif Folded = "OR" then return Tok_Or;
      elsif Folded = "NOT" then return Tok_Not;
      end if;
      return Tok_Ident;
   end Keyword_Of;

   function Peek_Token return Token is
      SP : constant Natural := Pos;
      SL : constant Natural := Cur_Line;
      SC : constant Natural := Cur_Col;
      T  : Token;
   begin
      T := Next_Token;
      Pos := SP;
      Cur_Line := SL;
      Cur_Col := SC;
      return T;
   end Peek_Token;

   procedure Peek_Token2 (T1, T2 : out Token) is
      SP : constant Natural := Pos;
      SL : constant Natural := Cur_Line;
      SC : constant Natural := Cur_Col;
   begin
      T1 := Next_Token;
      T2 := Next_Token;
      Pos := SP;
      Cur_Line := SL;
      Cur_Col := SC;
   end Peek_Token2;

   function Next_Token return Token is
      T  : Token;
      N  : Natural;
      C  : Character;
   begin
      T.Line := Cur_Line;
      T.Col := Cur_Col;

      --  Skip whitespace and (* ... *) comments (comments nest).
      loop
         C := Peek;
         if C = ' ' or else C = ASCII.HT or else C = ASCII.CR
           or else C = ASCII.LF
         then
            Advance;
         elsif C = '(' and then Pos + 1 < Len and then Src (Pos + 2) = '*' then
            Advance (2);
            declare
               Depth : Natural := 1;
            begin
               while Depth > 0 and then Pos < Len loop
                  if Peek = '(' and then Pos + 1 < Len
                    and then Src (Pos + 2) = '*'
                  then
                     Depth := Depth + 1;
                     Advance (2);
                  elsif Peek = '*' and then Pos + 1 < Len
                    and then Src (Pos + 2) = ')'
                  then
                     Depth := Depth - 1;
                     Advance (2);
                  else
                     Advance;
                  end if;
               end loop;
            end;
         else
            exit;
         end if;
      end loop;

      C := Peek;
      if Pos >= Len then
         T.Kind := Tok_EOF;
         return T;
      end if;

      if C in 'a' .. 'z' or else C in 'A' .. 'Z' then
         N := 0;
         loop
            C := Peek;
            exit when not (C in 'a' .. 'z' or else C in 'A' .. 'Z'
                           or else C in '0' .. '9');
            N := N + 1;
            T.Text (N) := C;
            Advance;
         end loop;
         T.Len := N;
         T.Kind := Keyword_Of (T.Text (1 .. N));
         return T;
      end if;

      if C in '0' .. '9' then
         N := 0;
         loop
            C := Peek;
            exit when not (C in '0' .. '9');
            N := N + 1;
            T.Text (N) := C;
            Advance;
         end loop;
         --  REAL literals: digits '.' digits (M18)
         if Peek = '.' and then Pos + 1 < Len
           and then Src (Pos + 2) in '0' .. '9'
         then
            Advance;              --  the '.'
            N := N + 1;
            T.Text (N) := '.';
            loop
               C := Peek;
               exit when not (C in '0' .. '9');
               N := N + 1;
               T.Text (N) := C;
               Advance;
            end loop;
         end if;
         T.Kind := Tok_Number;
         T.Len := N;
         return T;
      end if;

      if C = '"' then
         Advance;
         N := 0;
         loop
            C := Peek;
            if Pos >= Len then
               T.Kind := Tok_Error;
               return T;
            end if;
            if C = '"' then
               Advance;
               --  Doubled quote is an embedded quote (Oberon rule).
               if Peek = '"' then
                  N := N + 1;
                  T.Text (N) := '"';
                  Advance;
               else
                  T.Kind := Tok_String;
                  T.Len := N;
                  return T;
               end if;
            elsif C = ASCII.LF then
               T.Kind := Tok_Error;
               return T;
            else
               N := N + 1;
               T.Text (N) := C;
               Advance;
            end if;
         end loop;
      end if;

      --  Single-char and two-char symbols.
      T.Kind := Tok_Error;
      case C is
         when ';' => T.Kind := Tok_Semi; Advance;
         when ':' =>
            Advance;
            if Peek = '=' then T.Kind := Tok_Assign; Advance;
            else T.Kind := Tok_Colon; end if;
         when '.' => T.Kind := Tok_Dot; Advance;
         when ',' => T.Kind := Tok_Comma; Advance;
         when '(' => T.Kind := Tok_LParen; Advance;
         when ')' => T.Kind := Tok_RParen; Advance;
         when '[' => T.Kind := Tok_LBracket; Advance;
         when ']' => T.Kind := Tok_RBracket; Advance;
         when '{' => T.Kind := Tok_LBrace; Advance;
         when '}' => T.Kind := Tok_RBrace; Advance;
         when '+' => T.Kind := Tok_Plus; Advance;
         when '-' => T.Kind := Tok_Minus; Advance;
         when '*' => T.Kind := Tok_Star; Advance;
         when '/' => T.Kind := Tok_Slash; Advance;
         when '=' => T.Kind := Tok_Equal; Advance;
         when '#' => T.Kind := Tok_NE; Advance;
         when '<' =>
            Advance;
            if Peek = '=' then T.Kind := Tok_LE; Advance;
            else T.Kind := Tok_LT; end if;
         when '>' =>
            Advance;
            if Peek = '=' then T.Kind := Tok_GE; Advance;
            else T.Kind := Tok_GT; end if;
         when '~' => T.Kind := Tok_Tilde; Advance;
         when '&' => T.Kind := Tok_Amp; Advance;
         when '|' => T.Kind := Tok_Bar; Advance;
         when '^' => T.Kind := Tok_Caret; Advance;
         when others =>
            --  Unrecognized character: consume it so progress is
            --  guaranteed, keep the offending char in the token.
            T.Kind := Tok_Error;
            T.Text (1) := C;
            T.Len := 1;
            Advance;
      end case;

      if T.Len = 0 and then T.Kind /= Tok_Error then
         T.Len := 1;
         T.Text (1) := C;
      end if;
      return T;
   end Next_Token;

end O2c_Lexer;
