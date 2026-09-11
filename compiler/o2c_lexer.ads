--  o2c lexer (M1 Oberon-2 subset).
--
--  Deliberate deviation from the Oberon-2 spec (project decision):
--  keywords are case-insensitive (BEGIN, Begin and begin all lex as
--  the BEGIN keyword).  Identifiers remain case-sensitive per the
--  spec.  Comments are (* ... *) and nest, as in Oberon.
package O2c_Lexer is

   type Token_Kind is
     (Tok_EOF,
      Tok_Error,
      Tok_Ident,
      Tok_Number,
      Tok_String,
      --  reserved words (case-insensitive)
      Tok_Module, Tok_Import, Tok_Begin, Tok_End,
      Tok_Const, Tok_Var, Tok_Procedure, Tok_Type,
      Tok_Array, Tok_Of, Tok_Record, Tok_Pointer, Tok_Case,
      Tok_If, Tok_Then, Tok_Elsif, Tok_Else,
      Tok_While, Tok_Do, Tok_Repeat, Tok_Until,
      Tok_For, Tok_To, Tok_By, Tok_Loop, Tok_Exit, Tok_Return,
      Tok_True, Tok_False, Tok_Nil, Tok_Is, Tok_Extern,
      Tok_With, Tok_In,
      Tok_Div, Tok_Mod, Tok_And, Tok_Or, Tok_Not,
      --  symbols
      Tok_Semi, Tok_Colon, Tok_Assign, Tok_Dot, Tok_Comma,
      Tok_LParen, Tok_RParen, Tok_LBracket, Tok_RBracket,
      Tok_LBrace, Tok_RBrace,
      Tok_Plus, Tok_Minus, Tok_Star, Tok_Slash,
      Tok_Equal, Tok_NE, Tok_LT, Tok_LE, Tok_GT, Tok_GE,
      Tok_Tilde, Tok_Amp, Tok_Bar, Tok_Caret);

   Max_Token_Len : constant := 1024;

   type Token is record
      Kind : Token_Kind := Tok_EOF;
      Text : String (1 .. Max_Token_Len) := (others => ' ');
      Len  : Natural := 0;
      Line : Positive := 1;
      Col  : Positive := 1;
   end record;

   --  Start lexing Src (a full module source).
   procedure Init (Source : String);

   --  Scan and return the next token.
   function Next_Token return Token;

   --  Keyword lookup with case folding: Word is compared after
   --  uppercasing, so any spelling matches.  Returns Tok_Ident when
   --  Word is not a reserved word.
   function Keyword_Of (Word : String) return Token_Kind;

   --  Return the next token without consuming it.
   function Peek_Token return Token;

   --  Return the next two tokens without consuming them.
   procedure Peek_Token2 (T1, T2 : out Token);

   --  Human-readable kind name (for the shell demo / tests).
   function Image (Kind : Token_Kind) return String;

end O2c_Lexer;
