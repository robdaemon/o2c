with Ada.Strings.Unbounded;
with O2c_Lexer;

package body O2c_Compiler is

   use Ada.Strings.Unbounded;
   use type O2c_Lexer.Token_Kind;

   package Lex renames O2c_Lexer;

   type EType is (T_Int, T_Bool, T_Str);

   type Expr_Rec is record
      Text : Unbounded_String;
      Typ  : EType := T_Int;
   end record;

   Max_Syms   : constant := 256;
   Max_Params : constant := 8;

   type Sym_Kind is (S_Var, S_Const, S_Proc);

   type Param_Rec is record
      Name   : Unbounded_String;
      Typ    : EType := T_Int;
      By_Ref : Boolean := False;
   end record;

   type Param_Array is array (1 .. Max_Params) of Param_Rec;

   type Sym is record
      Kind   : Sym_Kind := S_Var;
      Typ    : EType := T_Int;
      Name   : Unbounded_String;
      Params : Natural := 0;
      P      : Param_Array := (others => <>);
   end record;

   Syms  : array (1 .. Max_Syms) of Sym := (others => <>);
   N_Sym : Natural := 0;

   Decl_Buf  : Unbounded_String;
   Body_Buf  : Unbounded_String;
   Cur       : Lex.Token;
   Mod_Name  : Unbounded_String;
   Used_Int  : Boolean := False;
   Seen_Proc : Boolean := False;

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
           & ", found " & Lex.Image (Cur.Kind) & " '"
           & Cur.Text (1 .. Cur.Len) & "'";
      end if;
   end Expect;

   function Ident_Text return String is
   begin
      Expect (Lex.Tok_Ident, "an identifier");
      return Cur.Text (1 .. Cur.Len);
   end Ident_Text;

   function Find (Name : String) return Natural is
   begin
      for I in reverse 1 .. N_Sym loop
         if To_String (Syms (I).Name) = Name then
            return I;
         end if;
      end loop;
      return 0;
   end Find;

   function Ada_Type (T : EType) return String is
   begin
      case T is
         when T_Int  => return "Integer";
         when T_Bool => return "Boolean";
         when T_Str  => return "String";
      end case;
   end Ada_Type;

   --  Standard type names fold like keywords: INTEGER/Integer/integer
   --  are all accepted in type position (case-insensitivity deviation).
   --  Ordinary identifiers stay case-sensitive.
   function Eq_No_Case (A, B : String) return Boolean is
      function Fold (C : Character) return Character is
      begin
         if C in 'a' .. 'z' then
            return Character'Val (Character'Pos (C) - 32);
         end if;
         return C;
      end Fold;
   begin
      if A'Length /= B'Length then
         return False;
      end if;
      for I in A'Range loop
         if Fold (A (I)) /= Fold (B (I - A'First + B'First)) then
            return False;
         end if;
      end loop;
      return True;
   end Eq_No_Case;

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

   --  forward specs
   function Parse_Expr return Expr_Rec;
   procedure Statement_Seq;
   procedure Decl_Const;
   procedure Decl_Var;
   procedure Decl_Procedure;

   --  expressions -------------------------------------------------

   function Parse_Factor return Expr_Rec is
      R  : Expr_Rec;
      Id : Natural;
   begin
      case Cur.Kind is
         when Lex.Tok_Number =>
            R.Text := To_Unbounded_String (Cur.Text (1 .. Cur.Len));
            R.Typ := T_Int;
            Next;
         when Lex.Tok_String =>
            R.Text := To_Unbounded_String
              (Ada_String_Literal (Cur.Text (1 .. Cur.Len)));
            R.Typ := T_Str;
            Next;
         when Lex.Tok_True =>
            R.Text := To_Unbounded_String ("True");
            R.Typ := T_Bool;
            Next;
         when Lex.Tok_False =>
            R.Text := To_Unbounded_String ("False");
            R.Typ := T_Bool;
            Next;
         when Lex.Tok_LParen =>
            Next;
            R := Parse_Expr;
            Expect (Lex.Tok_RParen, "')'");
            Next;
            R.Text := "(" & R.Text & ")";
         when Lex.Tok_Tilde | Lex.Tok_Not =>
            Next;
            R := Parse_Factor;
            if R.Typ /= T_Bool then
               raise O2c_Error with "NOT needs a BOOLEAN operand (line "
                 & Natural'Image (Cur.Line) & ")";
            end if;
            R.Text := "not (" & R.Text & ")";
         when Lex.Tok_Minus | Lex.Tok_Plus =>
            declare
               Neg : constant Boolean := Cur.Kind = Lex.Tok_Minus;
            begin
               Next;
               R := Parse_Factor;
               if R.Typ /= T_Int then
                  raise O2c_Error with "unary sign needs an INTEGER (line "
                    & Natural'Image (Cur.Line) & ")";
               end if;
               R.Text := (if Neg then "-" else "") & "(" & R.Text & ")";
            end;
         when Lex.Tok_Ident =>
            Id := Find (Cur.Text (1 .. Cur.Len));
            if Id = 0 or else Syms (Id).Kind = S_Proc then
               raise O2c_Error with "unknown variable or constant '"
                 & Cur.Text (1 .. Cur.Len) & "' (line "
                 & Natural'Image (Cur.Line) & ")";
            end if;
            R.Text := To_Unbounded_String (Cur.Text (1 .. Cur.Len));
            R.Typ := Syms (Id).Typ;
            Next;
         when others =>
            raise O2c_Error with "expression expected at line "
              & Natural'Image (Cur.Line);
      end case;
      return R;
   end Parse_Factor;

   function Parse_Term return Expr_Rec is
      R : Expr_Rec := Parse_Factor;
   begin
      loop
         if Cur.Kind = Lex.Tok_Star then
            Next;
            declare
               X : Expr_Rec := Parse_Factor;
            begin
               if R.Typ /= T_Int or else X.Typ /= T_Int then
                  raise O2c_Error with "'*' needs INTEGER operands";
               end if;
               R.Text := R.Text & " * " & X.Text;
            end;
         elsif Cur.Kind = Lex.Tok_Div then
            Next;
            declare
               X : Expr_Rec := Parse_Factor;
            begin
               if R.Typ /= T_Int or else X.Typ /= T_Int then
                  raise O2c_Error with "DIV needs INTEGER operands";
               end if;
               R.Text := R.Text & " / " & X.Text;
            end;
         elsif Cur.Kind = Lex.Tok_Mod then
            Next;
            declare
               X : Expr_Rec := Parse_Factor;
            begin
               if R.Typ /= T_Int or else X.Typ /= T_Int then
                  raise O2c_Error with "MOD needs INTEGER operands";
               end if;
               R.Text := R.Text & " rem " & X.Text;
            end;
         elsif Cur.Kind = Lex.Tok_Slash then
            raise O2c_Error with "'/' is real division, not in the M2 subset";
         elsif Cur.Kind = Lex.Tok_Amp then
            Next;
            declare
               X : Expr_Rec := Parse_Factor;
            begin
               if R.Typ /= T_Bool or else X.Typ /= T_Bool then
                  raise O2c_Error with "'&' needs BOOLEAN operands";
               end if;
               R.Text := R.Text & " and " & X.Text;
            end;
         else
            exit;
         end if;
      end loop;
      return R;
   end Parse_Term;

   function Parse_Simple return Expr_Rec is
      R : Expr_Rec := Parse_Term;
   begin
      loop
         if Cur.Kind = Lex.Tok_Plus then
            Next;
            declare
               X : Expr_Rec := Parse_Term;
            begin
               if R.Typ /= T_Int or else X.Typ /= T_Int then
                  raise O2c_Error with "'+' needs INTEGER operands";
               end if;
               R.Text := R.Text & " + " & X.Text;
            end;
         elsif Cur.Kind = Lex.Tok_Minus then
            Next;
            declare
               X : Expr_Rec := Parse_Term;
            begin
               if R.Typ /= T_Int or else X.Typ /= T_Int then
                  raise O2c_Error with "'-' needs INTEGER operands";
               end if;
               R.Text := R.Text & " - " & X.Text;
            end;
         elsif Cur.Kind = Lex.Tok_Or then
            Next;
            declare
               X : Expr_Rec := Parse_Term;
            begin
               if R.Typ /= T_Bool or else X.Typ /= T_Bool then
                  raise O2c_Error with "OR needs BOOLEAN operands";
               end if;
               R.Text := R.Text & " or " & X.Text;
            end;
         else
            exit;
         end if;
      end loop;
      return R;
   end Parse_Simple;

   function Parse_Expr return Expr_Rec is
      R : Expr_Rec := Parse_Simple;
   begin
      if Cur.Kind = Lex.Tok_Equal or else Cur.Kind = Lex.Tok_NE
        or else Cur.Kind = Lex.Tok_LT or else Cur.Kind = Lex.Tok_LE
        or else Cur.Kind = Lex.Tok_GT or else Cur.Kind = Lex.Tok_GE
      then
         declare
            Op : constant String :=
              (case Cur.Kind is
                 when Lex.Tok_Equal => " = ",
                 when Lex.Tok_NE    => " /= ",
                 when Lex.Tok_LT    => " < ",
                 when Lex.Tok_LE    => " <= ",
                 when Lex.Tok_GT    => " > ",
                 when others        => " >= ");
         begin
            Next;
            declare
               X : Expr_Rec := Parse_Simple;
            begin
               if R.Typ /= T_Int or else X.Typ /= T_Int then
                  raise O2c_Error with "comparisons need INTEGER operands";
               end if;
               R.Text := "(" & R.Text & Op & X.Text & ")";
               R.Typ := T_Bool;
            end;
         end;
      end if;
      return R;
   end Parse_Expr;

   --  declarations ------------------------------------------------

   procedure Decl_Const is
      Name : constant String := Ident_Text;
      V    : Expr_Rec;
   begin
      Next;                       --  past the name
      Expect (Lex.Tok_Equal, "'='");
      Next;
      V := Parse_Expr;
      Expect (Lex.Tok_Semi, "';'");
      Next;

      N_Sym := N_Sym + 1;
      Syms (N_Sym) := (Kind => S_Const, Typ => V.Typ,
                       Name => To_Unbounded_String (Name),
                       others => <>);
      Append_Decl ("   " & Name & " : constant " & Ada_Type (V.Typ)
                   & " := " & To_String (V.Text) & ";");
   end Decl_Const;

   procedure Decl_Var is
      Names : array (1 .. 16) of Unbounded_String;
      N     : Natural := 0;
      Typ   : EType;
      Init  : String (1 .. 1);
   begin
      while Cur.Kind = Lex.Tok_Ident loop
         N := N + 1;
         if N > Names'Last then
            raise O2c_Error with "too many names in one VAR list";
         end if;
         Names (N) := To_Unbounded_String (Cur.Text (1 .. Cur.Len));
         Next;
         exit when Cur.Kind /= Lex.Tok_Comma;
         Next;
      end loop;

      Expect (Lex.Tok_Colon, "':' in a VAR declaration");
      Next;
      if Cur.Kind = Lex.Tok_Ident then
         declare
            T : constant String := Cur.Text (1 .. Cur.Len);
         begin
            if Eq_No_Case (T, "INTEGER") then
               Typ := T_Int;
               Init := "0";
            elsif Eq_No_Case (T, "BOOLEAN") then
               Typ := T_Bool;
               Init := "F";
            else
               raise O2c_Error with "M2 variable types: INTEGER and BOOLEAN"
                 & " only ('" & T & "' at line " & Natural'Image (Cur.Line)
                 & ")";
            end if;
            Next;
         end;
      else
         raise O2c_Error with "a type name expected (line "
           & Natural'Image (Cur.Line) & ")";
      end if;
      Expect (Lex.Tok_Semi, "';'");
      Next;

      for I in 1 .. N loop
         N_Sym := N_Sym + 1;
         Syms (N_Sym) := (Kind => S_Var, Typ => Typ,
                          Name => Names (I), others => <>);
         Append_Decl ("   " & To_String (Names (I)) & " : "
                      & Ada_Type (Typ)
                      & " := " & (if Init = "0" then "0" else "False")
                      & ";");
      end loop;
   end Decl_Var;

   procedure Decl_Procedure is
      Name  : constant String := Ident_Text;
      PName : array (1 .. Max_Params) of Unbounded_String;
      PTyp  : array (1 .. Max_Params) of EType;
      PRef  : array (1 .. Max_Params) of Boolean;
      N_Par : Natural := 0;
      Param_Base : Natural;
      Hdr   : Unbounded_String;
   begin
      Seen_Proc := True;
      Next;
      if Cur.Kind = Lex.Tok_LParen then
         Next;
         loop
            declare
               By_Ref : Boolean := False;
            begin
               if Cur.Kind = Lex.Tok_Var then
                  By_Ref := True;
                  Next;
               end if;
               N_Par := N_Par + 1;
               if N_Par > Max_Params then
                  raise O2c_Error with "too many parameters";
               end if;
               PName (N_Par) := To_Unbounded_String (Ident_Text);
               Next;
               Expect (Lex.Tok_Colon, "':' in a parameter");
               Next;
               if Cur.Kind /= Lex.Tok_Ident then
                  raise O2c_Error with "a type name expected (line "
                    & Natural'Image (Cur.Line) & ")";
               end if;
               if Eq_No_Case (Cur.Text (1 .. Cur.Len), "INTEGER") then
                  PTyp (N_Par) := T_Int;
               elsif Eq_No_Case (Cur.Text (1 .. Cur.Len), "BOOLEAN") then
                  PTyp (N_Par) := T_Bool;
               else
                  raise O2c_Error with "M2 parameter types: INTEGER/BOOLEAN"
                    & " only ('" & Cur.Text (1 .. Cur.Len) & "')";
               end if;
               Next;
               PRef (N_Par) := By_Ref;
            end;
            --  Oberon separates formal parameter sections with ';'
            --  (',' is accepted too); statements use ',' for args.
            exit when Cur.Kind /= Lex.Tok_Comma
              and then Cur.Kind /= Lex.Tok_Semi;
            Next;
         end loop;
         Expect (Lex.Tok_RParen, "')' after the parameters");
         Next;
      end if;
      Expect (Lex.Tok_Semi, "';' after the procedure header");
      Next;

      N_Sym := N_Sym + 1;
      Syms (N_Sym) := (Kind => S_Proc, Name => To_Unbounded_String (Name),
                       Params => N_Par, others => <>);
      for I in 1 .. N_Par loop
         Syms (N_Sym).P (I) :=
           (Name => PName (I), Typ => PTyp (I), By_Ref => PRef (I));
      end loop;

      --  parameters are in scope for the body (popped after it)
      Param_Base := N_Sym;
      for I in 1 .. N_Par loop
         N_Sym := N_Sym + 1;
         Syms (N_Sym) := (Kind => S_Var, Typ => PTyp (I),
                          Name => PName (I), others => <>);
      end loop;

      Hdr := Hdr & "   procedure " & Name;
      if N_Par > 0 then
         Hdr := Hdr & " (";
         for I in 1 .. N_Par loop
            if I > 1 then
               Hdr := Hdr & "; ";
            end if;
            Hdr := Hdr & To_String (PName (I))
              & (if PRef (I) then " : in out " else " : ")
              & Ada_Type (PTyp (I));
         end loop;
         Hdr := Hdr & ")";
      end if;
      Append_Decl (To_String (Hdr) & " is");
      if Cur.Kind = Lex.Tok_Begin then
         declare
            Saved : constant Unbounded_String := Body_Buf;
         begin
            Body_Buf := Null_Unbounded_String;
            Append_Decl ("   begin");
            Next;
            Statement_Seq;        --  stops at END; fills Body_Buf
            if Length (Body_Buf) = 0 then
               Append_Decl ("      null;");
            else
               Decl_Buf := Decl_Buf & Body_Buf;
            end if;
            Body_Buf := Saved;
         end;
      end if;
      Expect (Lex.Tok_End, "'END'");
      Next;
      Expect (Lex.Tok_Ident, "the procedure name after END");
      if Cur.Text (1 .. Cur.Len) /= Name then
         raise O2c_Error with "END names '" & Cur.Text (1 .. Cur.Len)
           & "' but PROCEDURE was " & Name;
      end if;
      Next;
      Expect (Lex.Tok_Semi, "';' after END");
      Next;
      Append_Decl ("   end " & Name & ";");

      N_Sym := Param_Base;        --  drop parameter scope only
   end Decl_Procedure;

   --  statements ---------------------------------------------------

   procedure Statement_Seq is
      Head : String (1 .. 64);
      H_Len : Natural := 0;
      Idx  : Natural;
   begin
      loop
         exit when Cur.Kind = Lex.Tok_End or else Cur.Kind = Lex.Tok_EOF;

         if Cur.Kind = Lex.Tok_Ident then
            H_Len := Cur.Len;
            Head (1 .. H_Len) := Cur.Text (1 .. H_Len);
            Idx := Find (Head (1 .. H_Len));
            Next;

            if Cur.Kind = Lex.Tok_Dot then
               --  Out.String / Out.Int / Out.Ln
               Next;
               Expect (Lex.Tok_Ident, "a member name after '.'");
               declare
                  M_Len : constant Natural := Cur.Len;
                  Member : constant String := Cur.Text (1 .. M_Len);
                  M : Unbounded_String;
               begin
                  if Head (1 .. H_Len) /= "Out" then
                     raise O2c_Error with "M2 calls only module Out (found '"
                       & Head (1 .. H_Len) & "." & Member & "')";
                  end if;
                  Next;
                  if Member = "Ln" then
                     Append_Body ("      Aegir_User.Console.Put_Line ("""");");
                  elsif Member = "String" or else Member = "Int" then
                     Expect (Lex.Tok_LParen, "'(' after Out." & Member);
                     Next;
                     if Member = "String" then
                        declare
                           A : Expr_Rec := Parse_Expr;
                        begin
                           if A.Typ /= T_Str then
                              raise O2c_Error
                                with "Out.String needs a string argument";
                           end if;
                           M := A.Text;
                        end;
                     else
                        declare
                           A : Expr_Rec := Parse_Expr;
                        begin
                           if A.Typ /= T_Int then
                              raise O2c_Error
                                with "Out.Int needs an INTEGER argument";
                           end if;
                           M := A.Text;
                           Used_Int := True;
                        end;
                     end if;
                     if Cur.Kind = Lex.Tok_Comma then   --  optional width
                        Next;
                        declare
                           W : Expr_Rec := Parse_Expr;
                        begin
                           if W.Typ /= T_Int then
                              raise O2c_Error with "width must be INTEGER";
                           end if;
                        end;
                     end if;
                     Expect (Lex.Tok_RParen, "')'");
                     Next;
                     if Member = "String" then
                        Append_Body ("      Aegir_User.Console.Put ("
                                     & To_String (M) & ");");
                     else
                        Append_Body ("      O2c_Put_Int (" & To_String (M)
                                     & ");");
                     end if;
                  else
                     raise O2c_Error with "M2 supports Out.String/Out.Int/"
                       & "Out.Ln only (found Out." & Member & ")";
                  end if;
               end;
            elsif Cur.Kind = Lex.Tok_LParen then
               --  local procedure call with arguments
               if Idx = 0 or else Syms (Idx).Kind /= S_Proc then
                  raise O2c_Error with "'" & Head (1 .. H_Len)
                    & "' is not a declared procedure (line "
                    & Natural'Image (Cur.Line) & ")";
               end if;
               Next;
               declare
                  Args : array (1 .. Max_Params) of Unbounded_String;
                  N_A  : Natural := 0;
                  Call : Unbounded_String;
               begin
                  loop
                     exit when Cur.Kind = Lex.Tok_RParen;
                     N_A := N_A + 1;
                     if N_A > Max_Params then
                        raise O2c_Error with "too many arguments";
                     end if;
                     declare
                        A : Expr_Rec := Parse_Expr;
                     begin
                        Args (N_A) := A.Text;
                        if Syms (Idx).P (N_A).Typ /= A.Typ then
                           raise O2c_Error with "argument " & Natural'Image (N_A)
                             & " of " & Head (1 .. H_Len) & " has the wrong type";
                        end if;
                     end;
                     exit when Cur.Kind /= Lex.Tok_Comma;
                     Next;
                  end loop;
                  if N_A /= Syms (Idx).Params then
                     raise O2c_Error with Head (1 .. H_Len) & " expects "
                       & Natural'Image (Syms (Idx).Params) & " argument(s), got "
                       & Natural'Image (N_A);
                  end if;
                  Expect (Lex.Tok_RParen, "')'");
                  Next;
                  Call := Call & Head (1 .. H_Len) & " (";
                  for I in 1 .. N_A loop
                     if I > 1 then
                        Call := Call & ", ";
                     end if;
                     Call := Call & Args (I);
                  end loop;
                  Call := Call & ");";
                  Append_Body ("      " & To_String (Call));
               end;
            elsif Cur.Kind = Lex.Tok_Assign then
               --  assignment
               if Idx = 0 or else Syms (Idx).Kind /= S_Var then
                  raise O2c_Error with "'" & Head (1 .. H_Len)
                    & "' is not a variable (line " & Natural'Image (Cur.Line)
                    & ")";
               end if;
               Next;
               declare
                  V : Expr_Rec := Parse_Expr;
               begin
                  if Syms (Idx).Typ /= V.Typ or else V.Typ = T_Str then
                     raise O2c_Error with "type mismatch assigning "
                       & Head (1 .. H_Len);
                  end if;
                  Append_Body ("      " & Head (1 .. H_Len) & " := "
                               & To_String (V.Text) & ";");
               end;
            elsif Cur.Kind = Lex.Tok_Colon then
               raise O2c_Error with "unsupported ':' after identifier (line "
                 & Natural'Image (Cur.Line) & ")";
            else
               --  no-argument local procedure call
               if Idx = 0 or else Syms (Idx).Kind /= S_Proc
                 or else Syms (Idx).Params /= 0
               then
                  raise O2c_Error with "'" & Head (1 .. H_Len)
                    & "' is not a declared procedure (line "
                    & Natural'Image (Cur.Line) & ")";
               end if;
               Append_Body ("      " & Head (1 .. H_Len) & ";");
            end if;
         elsif Cur.Kind = Lex.Tok_Begin then
            --  no nested BEGIN/END blocks in the M2 subset
            raise O2c_Error with "nested BEGIN not in the M2 subset";
         else
            raise O2c_Error with "M2 statement expected at line "
              & Natural'Image (Cur.Line);
         end if;

         if Cur.Kind = Lex.Tok_Semi then
            Next;
         end if;
      end loop;
   end Statement_Seq;

   --  module --------------------------------------------------------

   function Compile (Source : String) return String is
      S : Unbounded_String;
   begin
      Decl_Buf := Null_Unbounded_String;
      Body_Buf := Null_Unbounded_String;
      Mod_Name := Null_Unbounded_String;
      N_Sym := 0;
      Used_Int := False;
      Seen_Proc := False;

      Lex.Init (Source);
      Next;

      Expect (Lex.Tok_Module, "'MODULE'");
      Next;
      Mod_Name := To_Unbounded_String (Ident_Text);
      Next;
      Expect (Lex.Tok_Semi, "';' after the module name");
      Next;

      if Cur.Kind = Lex.Tok_Import then
         Next;
         Expect (Lex.Tok_Ident, "an imported module name");
         if Cur.Text (1 .. Cur.Len) /= "Out" then
            raise O2c_Error with "M2 imports only Out (found '"
              & Cur.Text (1 .. Cur.Len) & "')";
         end if;
         Next;
         if Cur.Kind = Lex.Tok_Comma then
            raise O2c_Error with "M2 imports only Out";
         end if;
         Expect (Lex.Tok_Semi, "';'");
         Next;
      end if;

      loop
         exit when Cur.Kind = Lex.Tok_Begin or else Cur.Kind = Lex.Tok_End;
         if Cur.Kind = Lex.Tok_Const then
            if Seen_Proc then
               raise O2c_Error with "declare CONST/VAR before PROCEDUREs"
                 & " (M2 order rule)";
            end if;
            Next;
            while Cur.Kind = Lex.Tok_Ident loop
               Decl_Const;
            end loop;
         elsif Cur.Kind = Lex.Tok_Var then
            if Seen_Proc then
               raise O2c_Error with "declare CONST/VAR before PROCEDUREs"
                 & " (M2 order rule)";
            end if;
            Next;
            while Cur.Kind = Lex.Tok_Ident loop
               Decl_Var;
            end loop;
         elsif Cur.Kind = Lex.Tok_Procedure then
            Next;
            Decl_Procedure;
         else
            raise O2c_Error with "expected CONST/VAR/PROCEDURE/BEGIN/END"
              & " at line " & Natural'Image (Cur.Line);
         end if;
      end loop;

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

      S := S & "with Aegir_User.Console;" & ASCII.LF & ASCII.LF;
      S := S & "procedure " & To_String (Mod_Name) & " is" & ASCII.LF;
      if Used_Int then
         S := S & "   procedure O2c_Put_Int (V : Integer) is" & ASCII.LF
           & "      Img : constant String := Integer'Image (V);" & ASCII.LF
           & "   begin" & ASCII.LF
           & "      if Img (Img'First) = ' ' then" & ASCII.LF
           & "         Aegir_User.Console.Put (Img" & ASCII.LF
           & "           (Img'First + 1 .. Img'Last));" & ASCII.LF
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
