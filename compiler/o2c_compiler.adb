with Ada.Strings.Unbounded;
with O2c_Lexer;

package body O2c_Compiler is

   use Ada.Strings.Unbounded;
   use type O2c_Lexer.Token_Kind;

   package Lex renames O2c_Lexer;

   --  T_Ptr and T_Nil are typing sentinels (never reach Ada_Type):
   --  T_Ptr marks a pointer-value operand (Ptr_UT names its pointer
   --  user type), T_Nil marks the NIL literal.
   type EType is (T_Int, T_Bool, T_Str, T_Char, T_Ptr, T_Nil);

   type Expr_Rec is record
      Text   : Unbounded_String;
      Typ    : EType := T_Int;
      CStr   : Boolean := False;   --  whole ARRAY OF CHAR variable value
      Ptr_UT : Natural := 0;       --  pointer user-type index when T_Ptr
   end record;

   Max_Fields : constant := 32;
   Max_UTypes : constant := 32;

   type UField is record
      Name : Unbounded_String;
      Typ  : EType := T_Int;
      UT   : Natural := 0;         --  pointer user-type index for the
                                   --  field (M8); 0 = builtin scalar
   end record;

   type UField_Array is array (1 .. Max_Fields) of UField;

   type UType is record
      Name    : Unbounded_String;
      Is_Rec  : Boolean := True;
      Is_Ptr  : Boolean := False;   --  POINTER TO (target in Ptr_Tgt)
      Ptr_Tgt : Natural := 0;       --  record UT a pointer designates
      Pend    : Boolean := False;   --  POINTER TO a not-yet-declared
                                    --  target (buffer its access decl)
      Pend_Nm : Unbounded_String;   --  pending target name (when Pend)
      Arr_Len : Integer := 0;       --  arrays (0 = record or pointer)
      Elem    : EType := T_Int;     --  array element type
      N_F     : Natural := 0;
      F       : UField_Array := (others => <>);
   end record;

   UTypes : array (1 .. Max_UTypes) of UType := (others => <>);
   N_UT   : Natural := 0;

   Max_Syms   : constant := 256;
   Max_Params : constant := 8;

   type Sym_Kind is (S_Var, S_Const, S_Proc);

   type Param_Rec is record
      Name   : Unbounded_String;
      Typ    : EType := T_Int;
      By_Ref : Boolean := False;
      UT     : Natural := 0;      --  user type (record/array/pointer) index
   end record;

   type Param_Array is array (1 .. Max_Params) of Param_Rec;

   type Sym is record
      Kind   : Sym_Kind := S_Var;
      Typ    : EType := T_Int;
      Name   : Unbounded_String;
      Params : Natural := 0;
      Ret    : Boolean := False;   --  procedure is a function (returns Typ)
      UT     : Natural := 0;       --  user type index (0 = scalar Typ)
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
   In_Proc   : Boolean := False;   --  parsing inside a procedure body
   Cur_Proc_Ret : Boolean := False;
   Cur_Ret_Type : EType := T_Int;
   Cur_Ret_UT   : Natural := 0;   --  pointer return user type (M11)
   Ctrl_Depth   : Natural := 0;    --  open IF/WHILE/REPEAT/FOR/LOOP nesting
   Func_Return_Ok : Boolean := False;
   Used_CStr : Boolean := False;
   Loop_Depth : Natural := 0;      --  open LOOP statements (EXIT target)
   Loop_N     : Natural := 0;      --  LOOP counter for generated labels
   Loop_Lbl   : array (1 .. 64) of Unbounded_String;  --  per-depth label

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

   function Find_UT (Name : String) return Natural is
   begin
      for I in 1 .. N_UT loop
         if To_String (UTypes (I).Name) = Name then
            return I;
         end if;
      end loop;
      return 0;
   end Find_UT;

   function Field_Of (UT : Natural; Name : String) return Natural is
   begin
      for I in 1 .. UTypes (UT).N_F loop
         if To_String (UTypes (UT).F (I).Name) = Name then
            return I;
         end if;
      end loop;
      return 0;
   end Field_Of;

   function Starts_Expr (K : Lex.Token_Kind) return Boolean is
     (K = Lex.Tok_Ident or else K = Lex.Tok_Number
      or else K = Lex.Tok_String or else K = Lex.Tok_LParen
      or else K = Lex.Tok_Minus or else K = Lex.Tok_Plus
      or else K = Lex.Tok_Tilde or else K = Lex.Tok_Not
      or else K = Lex.Tok_True or else K = Lex.Tok_False
      or else K = Lex.Tok_Nil);

   function Ada_Type (T : EType) return String is
   begin
      case T is
         when T_Int  => return "Integer";
         when T_Bool => return "Boolean";
         when T_Str  => return "String";
         when T_Char => return "Character";
         when T_Ptr | T_Nil =>
            raise O2c_Error
              with "internal: Ada_Type on a pointer/NIL typing sentinel";
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

   function Builtin_Type_Of (Name : String) return EType is
   begin
      if Eq_No_Case (Name, "INTEGER") then
         return T_Int;
      elsif Eq_No_Case (Name, "BOOLEAN") then
         return T_Bool;
      elsif Eq_No_Case (Name, "CHAR") then
         return T_Char;
      end if;
      return T_Str;               --  sentinel: not a builtin scalar
   end Builtin_Type_Of;

   function Scalar_Init (T : EType) return String is
   begin
      if T = T_Int then
         return "0";
      elsif T = T_Char then
         return "ASCII.NUL";
      end if;
      return "False";
   end Scalar_Init;

   function Field_Init (F : UField) return String is
   begin
      if F.UT /= 0 then
         return "null";             --  pointer-typed field (M8)
      end if;
      return Scalar_Init (F.Typ);
   end Field_Init;

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
   procedure Statement_Seq (Stop_On_Else : Boolean := False;
                              Stop_On_Until : Boolean := False;
                              Stop_On_Bar : Boolean := False);
   procedure Decl_Const;
   procedure Decl_Var;
   procedure Decl_Type;
   procedure Decl_Procedure;

   --  expressions -------------------------------------------------

   type Desig_Kind is (D_Scalar, D_Ptr);

   type Desig is record
      Text : Unbounded_String;
      K    : Desig_Kind := D_Scalar;
      Sc   : EType := T_Int;      --  scalar type when D_Scalar
      UT   : Natural := 0;        --  pointer user type when D_Ptr
   end record;

   --  Parse the designator suffix after a POINTER/record-typed base
   --  variable (name consumed; Cur is the first token after it).
   --  Handles '^' (deref) and '.field' selectors and returns the
   --  final value: a scalar (D_Scalar) or a pointer (D_Ptr).  Ada text
   --  drops '^' because Ada access types auto-deref, so p^.next^.v
   --  becomes p.next.v.  A bare pointer variable is a valid D_Ptr
   --  operand (used in p = NIL / whole-pointer copies).
   function Parse_Rec_Ptr_Chain (Base_Name : String;
                                 Base_UT   : Natural)
     return Desig
   is
      D  : Desig;
      K  : Boolean;               --  True: current value is a record
      UT : Natural := Base_UT;    --  current record / pointer UT
   begin
      D.Text := To_Unbounded_String (Base_Name);
      K := not UTypes (UT).Is_Ptr;
      loop
         if Cur.Kind = Lex.Tok_Caret then
            if K then
               raise O2c_Error with "'^' needs a POINTER operand (line "
                 & Natural'Image (Cur.Line) & ")";
            end if;
            Next;
            K := True;
            UT := UTypes (UT).Ptr_Tgt;
            if UT = 0 then
               raise O2c_Error with "internal: deref of an unresolved "
                 & "POINTER TO (line " & Natural'Image (Cur.Line) & ")";
            end if;
         elsif Cur.Kind = Lex.Tok_Dot then
            if not K then
               raise O2c_Error with "'.' selects a record field; deref "
                 & "the POINTER with '^' first (line "
                 & Natural'Image (Cur.Line) & ")";
            end if;
            Next;
            Expect (Lex.Tok_Ident, "a field name");
            declare
               F : constant Natural := Field_Of (UT, Cur.Text (1 .. Cur.Len));
            begin
               if F = 0 then
                  raise O2c_Error with "no field '" & Cur.Text (1 .. Cur.Len)
                    & "' in record " & To_String (UTypes (UT).Name);
               end if;
               D.Text := D.Text & "." & To_String (UTypes (UT).F (F).Name);
               if UTypes (UT).F (F).UT /= 0 then
                  --  pointer-typed field: the designator value is now
                  --  a pointer that may itself be deref'd further
                  K := False;
                  UT := UTypes (UT).F (F).UT;
               else
                  D.K := D_Scalar;
                  D.Sc := UTypes (UT).F (F).Typ;
                  Next;           --  past the field name
                  return D;
               end if;
               Next;
            end;
         else
            exit;
         end if;
      end loop;
      if K then
         raise O2c_Error with "a record value needs '.field' here (line "
           & Natural'Image (Cur.Line) & ")";
      end if;
      D.K := D_Ptr;
      D.UT := UT;
      return D;
   end Parse_Rec_Ptr_Chain;

   --  Parse a POINTER value on the right of ':=' or as a NEW/pointer
   --  argument: a pointer designator (variable + selectors) or NIL.
   function Parse_Ptr_Value return Expr_Rec is
      R : Expr_Rec;
   begin
      if Cur.Kind = Lex.Tok_Nil then
         R.Typ := T_Nil;
         R.Text := To_Unbounded_String ("null");
         Next;
         return R;
      end if;
      if Cur.Kind /= Lex.Tok_Ident then
         raise O2c_Error with "a POINTER value or NIL expected (line "
           & Natural'Image (Cur.Line) & ")";
      end if;
      declare
         Id : constant Natural := Find (Cur.Text (1 .. Cur.Len));
         Nm : constant String := Cur.Text (1 .. Cur.Len);
      begin
         if Id = 0 or else Syms (Id).Kind /= S_Var then
            raise O2c_Error with "'" & Nm & "' is not a pointer variable "
              & "(line " & Natural'Image (Cur.Line) & ")";
         end if;
         Next;                   --  past the variable name
         if Syms (Id).UT /= 0
           and then (UTypes (Syms (Id).UT).Is_Ptr
                     or else UTypes (Syms (Id).UT).Is_Rec)
         then
            declare
               D : Desig := Parse_Rec_Ptr_Chain (Nm, Syms (Id).UT);
            begin
               if D.K /= D_Ptr then
                  raise O2c_Error with "a POINTER value or NIL expected "
                    & "(line " & Natural'Image (Cur.Line) & ")";
               end if;
               R.Typ := T_Ptr;
               R.Ptr_UT := D.UT;
               R.Text := D.Text;
            end;
         else
            raise O2c_Error with "'" & Nm & "' is not a pointer variable "
              & "(line " & Natural'Image (Cur.Line) & ")";
         end if;
      end;
      return R;
   end Parse_Ptr_Value;

   --  Parse one actual argument against a formal parameter (M11).
   --  Record/array formals are VAR-only, so their actual is a whole
   --  variable of exactly that type; pointer formals take a pointer
   --  value/designator of the same type or NIL (VAR rejects NIL);
   --  scalar formals keep the previous expression check.
   function Parse_Actual (Formal : Param_Rec) return Expr_Rec is
      A : Expr_Rec;
   begin
      if Formal.UT /= 0 and then not UTypes (Formal.UT).Is_Ptr then
         --  record/array VAR actual: a variable of exactly this type
         if Cur.Kind /= Lex.Tok_Ident then
            raise O2c_Error with "a variable of type "
              & To_String (UTypes (Formal.UT).Name) & " expected (line "
              & Natural'Image (Cur.Line) & ")";
         end if;
         declare
            Id : constant Natural := Find (Cur.Text (1 .. Cur.Len));
         begin
            if Id = 0 or else Syms (Id).Kind /= S_Var
              or else Syms (Id).UT /= Formal.UT
            then
               raise O2c_Error with "'" & Cur.Text (1 .. Cur.Len)
                 & "' is not a variable of type "
                 & To_String (UTypes (Formal.UT).Name) & " (line "
                 & Natural'Image (Cur.Line) & ")";
            end if;
            A.Text := To_Unbounded_String (Cur.Text (1 .. Cur.Len));
            Next;
            return A;
         end;
      end if;
      A := Parse_Expr;
      if Formal.UT = 0 then
         if A.Typ /= Formal.Typ then
            raise O2c_Error with "argument has the wrong type (line "
              & Natural'Image (Cur.Line) & ")";
         end if;
      else
         --  pointer formal (value or VAR)
         if A.Typ = T_Nil then
            if Formal.By_Ref then
               raise O2c_Error with "a VAR POINTER parameter needs a "
                 & "variable, not NIL (line "
                 & Natural'Image (Cur.Line) & ")";
            end if;
         elsif A.Typ /= T_Ptr or else A.Ptr_UT /= Formal.UT then
            raise O2c_Error with "argument must be a pointer of type "
              & To_String (UTypes (Formal.UT).Name) & " or NIL (line "
              & Natural'Image (Cur.Line) & ")";
         end if;
      end if;
      return A;
   end Parse_Actual;

   --  Assign a POINTER value (designator or NIL) to an Ada LHS whose
   --  pointer user type is LHS_UT; type-check the value first (M8).
   procedure Assign_Pointer (LHS : String; LHS_UT : Natural) is
      R : Expr_Rec := Parse_Expr;
   begin
      if R.Typ /= T_Nil and then
        (R.Typ /= T_Ptr or else R.Ptr_UT /= LHS_UT)
      then
         raise O2c_Error with "pointer type mismatch assigning " & LHS;
      end if;
      Append_Body ("      " & LHS & " := " & To_String (R.Text) & ";");
   end Assign_Pointer;

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
         when Lex.Tok_Nil =>
            R.Text := To_Unbounded_String ("null");
            R.Typ := T_Nil;
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
            if Id = 0 then
               raise O2c_Error with "unknown variable or constant '"
                 & Cur.Text (1 .. Cur.Len) & "' (line "
                 & Natural'Image (Cur.Line) & ")";
            end if;
            if Syms (Id).Kind = S_Proc then
               if not Syms (Id).Ret then
                  raise O2c_Error with "'" & Cur.Text (1 .. Cur.Len)
                    & "' is a proper procedure, not a function (line "
                    & Natural'Image (Cur.Line) & ")";
               end if;
               if Syms (Id).UT /= 0 then
                  --  function returning a POINTER (M11)
                  R.Typ := T_Ptr;
                  R.Ptr_UT := Syms (Id).UT;
               else
                  R.Typ := Syms (Id).Typ;
               end if;
               R.Text := To_Unbounded_String (Cur.Text (1 .. Cur.Len));
               Next;
               if Cur.Kind = Lex.Tok_LParen then
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
                           A : Expr_Rec :=
                             Parse_Actual (Syms (Id).P (N_A));
                        begin
                           Args (N_A) := A.Text;
                        end;
                        exit when Cur.Kind /= Lex.Tok_Comma;
                        Next;
                     end loop;
                     if N_A /= Syms (Id).Params then
                        raise O2c_Error with "call expects "
                          & Natural'Image (Syms (Id).Params)
                          & " argument(s), got " & Natural'Image (N_A);
                     end if;
                     Expect (Lex.Tok_RParen, "')'");
                     Next;
                     Call := Call & To_String (R.Text) & " (";
                     for I in 1 .. N_A loop
                        if I > 1 then
                           Call := Call & ", ";
                        end if;
                        Call := Call & Args (I);
                     end loop;
                     Call := Call & ")";
                     R.Text := Call;
                  end;
               elsif Syms (Id).Params /= 0 then
                  raise O2c_Error with "'" & Cur.Text (1 .. Cur.Len)
                    & "' needs arguments";
               end if;
               return R;
            end if;
            if Syms (Id).Kind = S_Var and then Syms (Id).UT /= 0 then
               declare
                  Nm : constant String := Cur.Text (1 .. Cur.Len);
                  U  : constant Natural := Syms (Id).UT;
               begin
                  Next;              --  past the variable name
                  if UTypes (U).Is_Ptr or else UTypes (U).Is_Rec then
                     --  POINTER/record designator: '^' deref and
                     --  '.field' selectors end on a scalar or pointer.
                     declare
                        D : Desig := Parse_Rec_Ptr_Chain (Nm, U);
                     begin
                        if D.K = D_Scalar then
                           R.Typ := D.Sc;
                        else
                           R.Typ := T_Ptr;
                           R.Ptr_UT := D.UT;
                        end if;
                        R.Text := D.Text;
                     end;
                     return R;
                  end if;
                  if UTypes (U).Elem = T_Char then
                     --  ARRAY OF CHAR: either the whole string value or
                     --  a single CHAR element s[i] (Ada index i + 1).
                     if Cur.Kind /= Lex.Tok_LBracket then
                        R.Text := To_Unbounded_String (Nm);
                        R.Typ := T_Str;
                        R.CStr := True;
                        return R;
                     end if;
                     Next;      --  past '['
                     declare
                        Ix : Expr_Rec := Parse_Expr;
                     begin
                        if Ix.Typ /= T_Int then
                           raise O2c_Error
                             with "string index must be INTEGER";
                        end if;
                        R.Text := To_Unbounded_String (Nm) & " ("
                          & Ix.Text & " + 1)";
                        R.Typ := T_Char;
                     end;
                     Expect (Lex.Tok_RBracket, "']'");
                     Next;
                     return R;
                  end if;
                  Expect (Lex.Tok_LBracket, "'[' to index an array");
                  Next;
                  declare
                     Ix : Expr_Rec := Parse_Expr;
                  begin
                     if Ix.Typ /= T_Int then
                        raise O2c_Error with "array index must be INTEGER";
                     end if;
                     R.Text := To_Unbounded_String (Nm) & " ("
                       & Ix.Text & ")";
                     R.Typ := UTypes (U).Elem;
                  end;
                  Expect (Lex.Tok_RBracket, "']'");
                  Next;
                  return R;
               end;
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
            Ordering : constant Boolean := Cur.Kind = Lex.Tok_LT
              or else Cur.Kind = Lex.Tok_LE
              or else Cur.Kind = Lex.Tok_GT
              or else Cur.Kind = Lex.Tok_GE;
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
               if Ordering then
                  if R.Typ /= T_Int or else X.Typ /= T_Int then
                     raise O2c_Error with "ordering comparisons need INTEGER"
                       & " operands";
                  end if;
               else
                  if R.Typ = T_Ptr or else R.Typ = T_Nil
                    or else X.Typ = T_Ptr or else X.Typ = T_Nil
                  then
                     --  pointer equality (M8): NIL against a pointer,
                     --  or two pointers of the same type
                     declare
                        R_P : constant Boolean := R.Typ = T_Ptr;
                        X_P : constant Boolean := X.Typ = T_Ptr;
                     begin
                        if R.Typ = T_Nil and then X.Typ = T_Nil then
                           raise O2c_Error with "comparing NIL with NIL is "
                             & "meaningless (line "
                             & Natural'Image (Cur.Line) & ")";
                        elsif R_P and then X_P then
                           if R.Ptr_UT /= X.Ptr_UT then
                              raise O2c_Error with "pointer types differ in "
                                & "'='/'#' comparison (line "
                                & Natural'Image (Cur.Line) & ")";
                           end if;
                        elsif not (R_P or X_P) then
                           raise O2c_Error with "'='/'#' compares a pointer "
                             & "with a non-pointer (line "
                             & Natural'Image (Cur.Line) & ")";
                        end if;
                     end;
                  else
                     declare
                        procedure Char_Coerce (E : in out Expr_Rec;
                                               Other : EType) is
                           T : constant String := To_String (E.Text);
                        begin
                           if E.Typ = T_Str and then Other = T_Char
                             and then T'Length = 3
                             and then T (T'First) = '"'
                             and then T (T'Last) = '"'
                           then
                              E.Typ := T_Char;
                              E.Text := To_Unbounded_String
                                ("'" & T (T'First + 1) & "'");
                           end if;
                        end Char_Coerce;
                     begin
                        Char_Coerce (R, X.Typ);
                        Char_Coerce (X, R.Typ);
                        if R.Typ /= X.Typ
                          or else (R.Typ /= T_Int and then R.Typ /= T_Bool
                                   and then R.Typ /= T_Char)
                        then
                           raise O2c_Error with "'='/'#' operands must match"
                             & " (INTEGER, BOOLEAN or CHAR)";
                        end if;
                     end;
                  end if;
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
      declare
         UT      : Natural := 0;
         Is_UT   : Boolean := False;
         Init_Txt : Unbounded_String;
      begin
         if Cur.Kind = Lex.Tok_Ident then
            declare
               T : constant String := Cur.Text (1 .. Cur.Len);
            begin
               Typ := Builtin_Type_Of (T);
               if Typ = T_Str then
                  UT := Find_UT (T);
                  if UT = 0 then
                     raise O2c_Error with "unknown type '" & T
                       & "' (line " & Natural'Image (Cur.Line) & ")";
                  end if;
                  Is_UT := True;
               end if;
               Next;
            end;
         else
            raise O2c_Error with "a type name expected (line "
              & Natural'Image (Cur.Line) & ")";
         end if;
         Expect (Lex.Tok_Semi, "';'");
         Next;

         if Is_UT then
            if UTypes (UT).Is_Ptr then
               Init_Txt := Init_Txt & "null";
            elsif UTypes (UT).Is_Rec then
               Init_Txt := Init_Txt & "(";
               for F in 1 .. UTypes (UT).N_F loop
                  if F > 1 then
                     Init_Txt := Init_Txt & ", ";
                  end if;
                  Init_Txt := Init_Txt & To_String (UTypes (UT).F (F).Name)
                    & " => " & Field_Init (UTypes (UT).F (F));
               end loop;
               Init_Txt := Init_Txt & ")";
            else
               Init_Txt := Init_Txt & "(others => "
                 & Scalar_Init (UTypes (UT).Elem) & ")";
            end if;
            for I in 1 .. N loop
               N_Sym := N_Sym + 1;
               Syms (N_Sym) := (Kind => S_Var, Typ => T_Int, UT => UT,
                                Name => Names (I), others => <>);
               Append_Decl ("   " & To_String (Names (I)) & " : "
                            & To_String (UTypes (UT).Name) & " := "
                            & To_String (Init_Txt) & ";");
            end loop;
         else
            for I in 1 .. N loop
               N_Sym := N_Sym + 1;
               Syms (N_Sym) := (Kind => S_Var, Typ => Typ,
                                Name => Names (I), others => <>);
               Append_Decl ("   " & To_String (Names (I)) & " : "
                            & Ada_Type (Typ) & " := " & Scalar_Init (Typ)
                            & ";");
            end loop;
         end if;
      end;
   end Decl_Var;

   procedure Decl_Type is
      Name : constant String := Ident_Text;
      UTI  : Natural;
   begin
      if Find_UT (Name) /= 0 then
         raise O2c_Error with "type '" & Name & "' is already declared "
           & "(line " & Natural'Image (Cur.Line) & ")";
      end if;
      Next;                       --  past the type name
      Expect (Lex.Tok_Equal, "'='");
      Next;

      N_UT := N_UT + 1;
      if N_UT > UTypes'Last then
         raise O2c_Error with "too many type declarations";
      end if;
      UTI := N_UT;
      UTypes (UTI) := (Name => To_Unbounded_String (Name),
                       Is_Rec => True, others => <>);

      if Cur.Kind = Lex.Tok_Array then
         Next;
         Expect (Lex.Tok_Number, "an array length");
         declare
            L : constant Integer := Integer'Value (Cur.Text (1 .. Cur.Len));
         begin
            if L <= 0 then
               raise O2c_Error with "array length must be positive";
            end if;
            UTypes (UTI).Arr_Len := L;
            Next;
         end;
         Expect (Lex.Tok_Of, "'OF'");
         Next;
         if Cur.Kind /= Lex.Tok_Ident then
            raise O2c_Error with "an element type expected";
         end if;
         UTypes (UTI).Elem := Builtin_Type_Of (Cur.Text (1 .. Cur.Len));
         if UTypes (UTI).Elem = T_Str then
            raise O2c_Error with "array element types: INTEGER/BOOLEAN/CHAR"
              & " only ('" & Cur.Text (1 .. Cur.Len) & "')";
         end if;
         Next;
         UTypes (UTI).Is_Rec := False;
         if UTypes (UTI).Elem = T_Char then
            Append_Decl ("   subtype " & Name & " is String (1 .. "
                         & Integer'Image (UTypes (UTI).Arr_Len) & ");");
         else
            Append_Decl ("   type " & Name & " is array (0 .. "
                         & Integer'Image (UTypes (UTI).Arr_Len - 1)
                         & ") of " & Ada_Type (UTypes (UTI).Elem) & ";");
         end if;
      elsif Cur.Kind = Lex.Tok_Pointer then
         --  POINTER TO <record type> (M8).  The classic idiom
         --    Node = POINTER TO NodeDesc;
         --    NodeDesc = RECORD ... next: Node ... END;
         --  declares the pointer before its record, so the access decl
         --  is buffered (Pend) and flushed when the record is declared.
         Next;                       --  past POINTER
         Expect (Lex.Tok_To, "'TO'");
         Next;
         if Cur.Kind /= Lex.Tok_Ident then
            raise O2c_Error with "a record type name expected after "
              & "POINTER TO (line " & Natural'Image (Cur.Line) & ")";
         end if;
         declare
            TName : constant String := Cur.Text (1 .. Cur.Len);
            TGT   : Natural;
         begin
            Next;
            UTypes (UTI).Is_Ptr := True;
            UTypes (UTI).Is_Rec := False;
            TGT := Find_UT (TName);
            if TGT = 0 then
               UTypes (UTI).Pend := True;
               UTypes (UTI).Pend_Nm := To_Unbounded_String (TName);
            else
               if not UTypes (TGT).Is_Rec then
                  raise O2c_Error with "POINTER TO target '" & TName
                    & "' must be a RECORD type (line "
                    & Natural'Image (Cur.Line) & ")";
               end if;
               UTypes (UTI).Ptr_Tgt := TGT;
               Append_Decl ("   type " & Name & " is access " & TName & ";");
            end if;
         end;
      elsif Cur.Kind = Lex.Tok_Record then
         Next;
         loop
            exit when Cur.Kind = Lex.Tok_End;
            declare
               FNames : array (1 .. 16) of Unbounded_String;
               NF     : Natural := 0;
               FT     : EType;
               FUT    : Natural := 0;  --  pointer user type (M8), 0 = scalar
            begin
               while Cur.Kind = Lex.Tok_Ident loop
                  NF := NF + 1;
                  if NF > FNames'Last then
                     raise O2c_Error with "too many fields in one section";
                  end if;
                  FNames (NF) := To_Unbounded_String (Cur.Text (1 .. Cur.Len));
                  Next;
                  exit when Cur.Kind /= Lex.Tok_Comma;
                  Next;
               end loop;
               Expect (Lex.Tok_Colon, "':' in a record field section");
               Next;
               if Cur.Kind /= Lex.Tok_Ident then
                  raise O2c_Error with "a field type expected";
               end if;
               declare
                  TN : constant String := Cur.Text (1 .. Cur.Len);
               begin
                  FT := Builtin_Type_Of (TN);
                  if FT = T_Str then
                     FUT := Find_UT (TN);
                     if FUT = 0 then
                        raise O2c_Error with "field types: INTEGER/BOOLEAN/"
                          & "CHAR or an earlier POINTER type only ('" & TN
                          & "')";
                     elsif not UTypes (FUT).Is_Ptr then
                        raise O2c_Error with "record field '" & TN
                          & "' must be a scalar or a POINTER type (M8)";
                     end if;
                     FT := T_Int;      --  scalar slot unused for pointers
                  end if;
               end;
               Next;
               if Cur.Kind = Lex.Tok_Semi then
                  Next;             --  optional separator before END
               end if;
               for I in 1 .. NF loop
                  UTypes (UTI).N_F := UTypes (UTI).N_F + 1;
                  if UTypes (UTI).N_F > Max_Fields then
                     raise O2c_Error with "too many record fields";
                  end if;
                  UTypes (UTI).F (UTypes (UTI).N_F) :=
                    (Name => FNames (I), Typ => FT, UT => FUT);
               end loop;
            end;
         end loop;
         Expect (Lex.Tok_End, "'END' closing the RECORD");
         Next;
         --  Flush POINTER TO this record declared earlier in the TYPE
         --  list: Ada wants the incomplete type, then the access type,
         --  then the full record to complete it.
         declare
            First_Pend : Boolean := True;
         begin
            for P in 1 .. N_UT loop
               if UTypes (P).Is_Ptr and then UTypes (P).Pend
                 and then To_String (UTypes (P).Pend_Nm) = Name
               then
                  if First_Pend then
                     Append_Decl ("   type " & Name & ";");
                     First_Pend := False;
                  end if;
                  UTypes (P).Ptr_Tgt := UTI;
                  UTypes (P).Pend := False;
                  Append_Decl ("   type " & To_String (UTypes (P).Name)
                               & " is access " & Name & ";");
               end if;
            end loop;
         end;
         Append_Decl ("   type " & Name & " is record");
         for F in 1 .. UTypes (UTI).N_F loop
            declare
               Fl : UField renames UTypes (UTI).F (F);
            begin
               Append_Decl ("      " & To_String (Fl.Name) & " : "
                            & (if Fl.UT /= 0
                              then To_String (UTypes (Fl.UT).Name)
                              else Ada_Type (Fl.Typ))
                            & " := " & Field_Init (Fl) & ";");
            end;
         end loop;
         Append_Decl ("   end record;");
      else
         raise O2c_Error with "expected ARRAY, RECORD or POINTER in type "
           & Name;
      end if;

      Expect (Lex.Tok_Semi, "';'");
      Next;
   end Decl_Type;

   procedure Decl_Procedure is
      Name  : constant String := Ident_Text;
      PName : array (1 .. Max_Params) of Unbounded_String;
      PTyp  : array (1 .. Max_Params) of EType;
      PUT   : array (1 .. Max_Params) of Natural := (others => 0);
      PRef  : array (1 .. Max_Params) of Boolean;
      N_Par : Natural := 0;
      Param_Base : Natural;
      Local_N_UT : Natural := 0;  --  UTypes count before locals (M10)
      Ret_Typ : EType := T_Int;
      Ret_UT  : Natural := 0;     --  pointer return user type (M11)
      Is_Function : Boolean := False;
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
               declare
                  TN : constant String := Cur.Text (1 .. Cur.Len);
               begin
                  PTyp (N_Par) := Builtin_Type_Of (TN);
                  if PTyp (N_Par) = T_Str then
                     PUT (N_Par) := Find_UT (TN);
                     if PUT (N_Par) = 0 then
                        raise O2c_Error with "unknown type '" & TN
                          & "' (line " & Natural'Image (Cur.Line) & ")";
                     end if;
                     if not UTypes (PUT (N_Par)).Is_Ptr then
                        --  records and arrays are VAR-only (M11): the
                        --  Oberon-2 report has no structured value params
                        if not By_Ref then
                           raise O2c_Error with "record/array parameters "
                             & "must be declared VAR ('" & TN & "', line "
                             & Natural'Image (Cur.Line) & ")";
                        end if;
                     end if;
                  end if;
               end;
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
      --  optional function return type
      Ret_Typ := T_Int;
      Ret_UT := 0;
      if Cur.Kind = Lex.Tok_Colon then
         Next;
         if Cur.Kind /= Lex.Tok_Ident then
            raise O2c_Error with "a return type name expected (line "
              & Natural'Image (Cur.Line) & ")";
         end if;
         declare
            TN : constant String := Cur.Text (1 .. Cur.Len);
         begin
            Ret_Typ := Builtin_Type_Of (TN);
            if Ret_Typ = T_Str then
               Ret_UT := Find_UT (TN);
               if Ret_UT = 0 then
                  raise O2c_Error with "unknown type '" & TN
                    & "' (line " & Natural'Image (Cur.Line) & ")";
               end if;
               if not UTypes (Ret_UT).Is_Ptr then
                  raise O2c_Error with "function return types: INTEGER/"
                    & "BOOLEAN/CHAR or a POINTER type ('" & TN & "', line "
                    & Natural'Image (Cur.Line) & ")";
               end if;
            end if;
         end;
         Next;
         Is_Function := True;
      end if;
      Expect (Lex.Tok_Semi, "';' after the procedure header");
      Next;

      N_Sym := N_Sym + 1;
      Syms (N_Sym) := (Kind => S_Proc, Name => To_Unbounded_String (Name),
                       Params => N_Par, Typ => Ret_Typ, UT => Ret_UT,
                       Ret => Is_Function, others => <>);
      for I in 1 .. N_Par loop
         Syms (N_Sym).P (I) :=
           (Name => PName (I), Typ => PTyp (I), By_Ref => PRef (I),
            UT => PUT (I));
      end loop;

      --  parameters are in scope for the body (popped after it)
      Param_Base := N_Sym;
      for I in 1 .. N_Par loop
         N_Sym := N_Sym + 1;
         Syms (N_Sym) := (Kind => S_Var, Typ => PTyp (I), UT => PUT (I),
                          Name => PName (I), others => <>);
      end loop;

      Hdr := Hdr & "   " & (if Is_Function then "function " else "procedure ")
        & Name;
      if N_Par > 0 then
         Hdr := Hdr & " (";
         for I in 1 .. N_Par loop
            if I > 1 then
               Hdr := Hdr & "; ";
            end if;
            Hdr := Hdr & To_String (PName (I))
              & (if PRef (I) then " : in out " else " : ")
              & (if PUT (I) /= 0 then To_String (UTypes (PUT (I)).Name)
                 else Ada_Type (PTyp (I)));
         end loop;
         Hdr := Hdr & ")";
      end if;
      if Is_Function then
         Hdr := Hdr & " return "
           & (if Ret_UT /= 0 then To_String (UTypes (Ret_UT).Name)
              else Ada_Type (Ret_Typ));
      end if;
      Append_Decl (To_String (Hdr) & " is");
      --  local declarations (M10): optional CONST/TYPE/VAR sections
      --  between the header and BEGIN.  Their symbols push onto the
      --  table after the parameters (so locals may shadow parameters
      --  and module names) and are dropped with the parameters at END;
      --  procedure-local types live at the tail of UTypes and are
      --  dropped when the procedure ends.
      Local_N_UT := N_UT;
      loop
         exit when Cur.Kind = Lex.Tok_Begin or else Cur.Kind = Lex.Tok_End;
         if Cur.Kind = Lex.Tok_Const then
            Next;
            while Cur.Kind = Lex.Tok_Ident loop
               Decl_Const;
            end loop;
         elsif Cur.Kind = Lex.Tok_Type then
            Next;
            while Cur.Kind = Lex.Tok_Ident loop
               Decl_Type;
            end loop;
         elsif Cur.Kind = Lex.Tok_Var then
            Next;
            while Cur.Kind = Lex.Tok_Ident loop
               Decl_Var;
            end loop;
         else
            raise O2c_Error with "expected CONST/TYPE/VAR or BEGIN in "
              & "procedure " & Name & " (line "
              & Natural'Image (Cur.Line) & ")";
         end if;
      end loop;
      --  a procedure-local POINTER TO must resolve inside this procedure
      for I in Local_N_UT + 1 .. N_UT loop
         if UTypes (I).Is_Ptr and then UTypes (I).Pend then
            raise O2c_Error with "POINTER TO "
              & To_String (UTypes (I).Pend_Nm) & " (type "
              & To_String (UTypes (I).Name)
              & ") has no RECORD declaration in procedure " & Name;
         end if;
      end loop;
      if Cur.Kind /= Lex.Tok_Begin then
         raise O2c_Error with "procedure " & Name
           & " needs a BEGIN body after its declarations (line "
           & Natural'Image (Cur.Line) & ")";
      end if;
      if Cur.Kind = Lex.Tok_Begin then
         declare
            Saved : constant Unbounded_String := Body_Buf;
         begin
            Body_Buf := Null_Unbounded_String;
            Append_Decl ("   begin");
            Next;
            Cur_Proc_Ret := Is_Function;
            Cur_Ret_Type := Ret_Typ;
            Cur_Ret_UT := Ret_UT;
            Func_Return_Ok := False;
            In_Proc := True;
            Statement_Seq;        --  stops at END; fills Body_Buf
            In_Proc := False;
            if Is_Function and then not Func_Return_Ok then
               raise O2c_Error with "function " & Name
                 & " must end with a RETURN statement";
            end if;
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

      N_Sym := Param_Base;        --  drop parameters and locals
      N_UT := Local_N_UT;         --  drop procedure-local types (M10)
   end Decl_Procedure;

   --  A buffered POINTER TO whose target record never appeared is an
   --  error once the module moves past the TYPE declarations: the Ada
   --  output would reference an undeclared access target.
   procedure Check_No_Pending is
   begin
      for I in 1 .. N_UT loop
         if UTypes (I).Is_Ptr and then UTypes (I).Pend then
            raise O2c_Error with "POINTER TO "
              & To_String (UTypes (I).Pend_Nm) & " (type "
              & To_String (UTypes (I).Name)
              & ") has no RECORD declaration (declare the target before "
              & "the first VAR/PROCEDURE/BEGIN)";
         end if;
      end loop;
   end Check_No_Pending;

   --  statements ---------------------------------------------------

   function At_Stop (Stop_Else, Stop_Until, Stop_Bar : Boolean)
     return Boolean is
     (Cur.Kind = Lex.Tok_End or else Cur.Kind = Lex.Tok_EOF
      or else (Stop_Else and then
               (Cur.Kind = Lex.Tok_Elsif or else Cur.Kind = Lex.Tok_Else))
      or else (Stop_Until and then Cur.Kind = Lex.Tok_Until)
      or else (Stop_Bar and then Cur.Kind = Lex.Tok_Bar));

   procedure Parse_If is
      Cond : Expr_Rec;
      Branch : Boolean := True;      --  True: emit "if", later "elsif"
   begin
      loop
         Next;                       --  consume IF / ELSIF
         Cond := Parse_Expr;
         if Cond.Typ /= T_Bool then
            raise O2c_Error with "IF/ELSIF condition must be BOOLEAN (line "
              & Natural'Image (Cur.Line) & ")";
         end if;
         Expect (Lex.Tok_Then, "'THEN'");
         Next;
         Append_Body ("      " & (if Branch then "if " else "elsif ")
                      & To_String (Cond.Text) & " then");
         Branch := False;
         declare
            Before : constant Natural := Length (Body_Buf);
         begin
            Ctrl_Depth := Ctrl_Depth + 1;
            Statement_Seq (Stop_On_Else => True);
            Ctrl_Depth := Ctrl_Depth - 1;
            if Length (Body_Buf) = Before then
               Append_Body ("         null;");
            end if;
         end;
         if Cur.Kind = Lex.Tok_Elsif then
            null;                    --  loop consumes the ELSIF
         elsif Cur.Kind = Lex.Tok_Else then
            Append_Body ("      else");
            Next;                    --  past ELSE
            declare
               Before : constant Natural := Length (Body_Buf);
            begin
               Ctrl_Depth := Ctrl_Depth + 1;
               Statement_Seq;        --  until END
               Ctrl_Depth := Ctrl_Depth - 1;
               if Length (Body_Buf) = Before then
                  Append_Body ("         null;");
               end if;
            end;
            exit;
         else
            exit;                    --  END closes the IF
         end if;
      end loop;
      Expect (Lex.Tok_End, "'END' closing the IF");
      Next;
      Append_Body ("      end if;");
   end Parse_If;

   procedure Parse_While is
      Cond : Expr_Rec;
   begin
      Next;                          --  WHILE
      Cond := Parse_Expr;
      if Cond.Typ /= T_Bool then
         raise O2c_Error with "WHILE condition must be BOOLEAN (line "
           & Natural'Image (Cur.Line) & ")";
      end if;
      Expect (Lex.Tok_Do, "'DO'");
      Next;
      Append_Body ("      while " & To_String (Cond.Text) & " loop");
      declare
         Before : constant Natural := Length (Body_Buf);
      begin
         Ctrl_Depth := Ctrl_Depth + 1;
         Statement_Seq;              --  until END
         Ctrl_Depth := Ctrl_Depth - 1;
         if Length (Body_Buf) = Before then
            Append_Body ("         null;");
         end if;
      end;
      Expect (Lex.Tok_End, "'END' closing the WHILE");
      Next;
      Append_Body ("      end loop;");
   end Parse_While;

   procedure Parse_Repeat is
      Cond : Expr_Rec;
   begin
      Next;                          --  REPEAT
      Append_Body ("      loop");
      declare
         Before : constant Natural := Length (Body_Buf);
      begin
         Ctrl_Depth := Ctrl_Depth + 1;
         Statement_Seq (Stop_On_Until => True);
         Ctrl_Depth := Ctrl_Depth - 1;
         if Length (Body_Buf) = Before then
            Append_Body ("         null;");
         end if;
      end;
      Expect (Lex.Tok_Until, "'UNTIL'");
      Next;
      Cond := Parse_Expr;
      if Cond.Typ /= T_Bool then
         raise O2c_Error with "UNTIL condition must be BOOLEAN (line "
           & Natural'Image (Cur.Line) & ")";
      end if;
      Append_Body ("      exit when " & To_String (Cond.Text) & ";");
      Append_Body ("      end loop;");
   end Parse_Repeat;

   procedure Parse_Loop is
      --  Oberon-2 LOOP ... END: an infinite loop; EXIT leaves it.  The
      --  Ada loop gets a generated label so that EXIT always leaves the
      --  LOOP even from inside a nested WHILE/REPEAT/FOR (a bare Ada
      --  'exit' would leave the innermost Ada loop instead).
   begin
      Next;                          --  LOOP
      Loop_Depth := Loop_Depth + 1;
      if Loop_Depth > Loop_Lbl'Last then
         Loop_Depth := Loop_Depth - 1;
         raise O2c_Error with "LOOP nesting too deep (line "
           & Natural'Image (Cur.Line) & ")";
      end if;
      Loop_N := Loop_N + 1;
      declare
         Img : constant String := Natural'Image (Loop_N);
         Lbl : constant String := "O2c_Loop_"
           & Img (Img'First + 1 .. Img'Last);
      begin
         Loop_Lbl (Loop_Depth) := To_Unbounded_String (Lbl);
         Append_Body ("      " & Lbl & " : loop");
         declare
            Before : constant Natural := Length (Body_Buf);
         begin
            Ctrl_Depth := Ctrl_Depth + 1;
            Statement_Seq;              --  until END
            Ctrl_Depth := Ctrl_Depth - 1;
            if Length (Body_Buf) = Before then
               Append_Body ("         null;");
            end if;
         end;
         Expect (Lex.Tok_End, "'END' closing the LOOP");
         Next;
         Append_Body ("      end loop " & Lbl & ";");
      end;
      Loop_Depth := Loop_Depth - 1;
   end Parse_Loop;

   procedure Parse_Exit is
   begin
      if Loop_Depth = 0 then
         raise O2c_Error with "EXIT is only allowed inside a LOOP "
           & "statement (line " & Natural'Image (Cur.Line) & ")";
      end if;
      Next;                          --  past EXIT
      Append_Body ("      exit " & To_String (Loop_Lbl (Loop_Depth)) & ";");
   end Parse_Exit;

   procedure Parse_For is
      V_Name : String (1 .. 64);
      V_Len  : Natural;
      Idx    : Natural;
      Lo, Hi : Expr_Rec;
      By_Text : Unbounded_String;
      Asc    : Boolean;
   begin
      Next;                          --  FOR
      V_Len := Cur.Len;
      V_Name (1 .. V_Len) := Cur.Text (1 .. V_Len);
      Idx := Find (V_Name (1 .. V_Len));
      if Idx = 0 or else Syms (Idx).Kind /= S_Var
        or else Syms (Idx).Typ /= T_Int
      then
         raise O2c_Error with "FOR needs an INTEGER variable ('"
           & V_Name (1 .. V_Len) & "')";
      end if;
      Next;
      Expect (Lex.Tok_Assign, "':=' in a FOR header");
      Next;
      Lo := Parse_Expr;
      if Lo.Typ /= T_Int then
         raise O2c_Error with "FOR bounds must be INTEGER";
      end if;
      Expect (Lex.Tok_To, "'TO'");
      Next;
      Hi := Parse_Expr;
      if Hi.Typ /= T_Int then
         raise O2c_Error with "FOR bounds must be INTEGER";
      end if;
      By_Text := To_Unbounded_String ("1");
      if Cur.Kind = Lex.Tok_By then
         Next;
         declare
            B : Expr_Rec := Parse_Expr;
            T : constant String := To_String (B.Text);
            All_Digits : Boolean := True;
         begin
            if B.Typ /= T_Int then
               raise O2c_Error with "FOR BY must be an integer constant";
            end if;
            for I in T'Range loop
               if I /= T'First or else T (I) /= '-' then
                  if T (I) not in '0' .. '9' then
                     All_Digits := False;
                  end if;
               end if;
            end loop;
            if not All_Digits then
               raise O2c_Error with "FOR BY must be an integer constant (M3)";
            end if;
            By_Text := B.Text;
         end;
      end if;
      Expect (Lex.Tok_Do, "'DO'");
      Next;
      Asc := To_String (By_Text) (1) /= '-';
      Append_Body ("      " & V_Name (1 .. V_Len) & " := "
                   & To_String (Lo.Text) & ";");
      Append_Body ("      while " & V_Name (1 .. V_Len) & " "
                   & (if Asc then "<=" else ">=") & " "
                   & To_String (Hi.Text) & " loop");
      declare
         Before : constant Natural := Length (Body_Buf);
      begin
         Ctrl_Depth := Ctrl_Depth + 1;
         Statement_Seq;              --  until END
         Ctrl_Depth := Ctrl_Depth - 1;
         if Length (Body_Buf) = Before then
            Append_Body ("         null;");
         end if;
      end;
      Expect (Lex.Tok_End, "'END' closing the FOR");
      Next;
      Append_Body ("      " & V_Name (1 .. V_Len) & " := "
                   & V_Name (1 .. V_Len) & " + " & To_String (By_Text) & ";");
      Append_Body ("      end loop;");
   end Parse_For;

   procedure Parse_Case is
      Sel : Expr_Rec;
      Used_Else : Boolean := False;
   begin
      Next;                       --  CASE
      Sel := Parse_Expr;
      if Sel.Typ /= T_Int then
         raise O2c_Error with "CASE selector must be INTEGER (line "
           & Natural'Image (Cur.Line) & ")";
      end if;
      Expect (Lex.Tok_Of, "'OF'");
      Next;
      Append_Body ("      case " & To_String (Sel.Text) & " is");

      --  alternatives: label {"," label} ":" seq  separated by "|",
      --  optional ELSE, closed by END
      loop
         if Cur.Kind = Lex.Tok_Else then
            if Used_Else then
               raise O2c_Error with "duplicate CASE ELSE";
            end if;
            Used_Else := True;
            Append_Body ("      when others =>");
            Next;
         else
            declare
               Labels : Unbounded_String;
               First  : Boolean := True;
            begin
               loop
                  --  one integer label (range labels not in M7)
                  if Cur.Kind = Lex.Tok_Minus then
                     Next;
                     Expect (Lex.Tok_Number, "a label after '-'");
                     if First then
                        Labels := To_Unbounded_String ("-")
                          & Cur.Text (1 .. Cur.Len);
                     else
                        Labels := Labels & " | -" & Cur.Text (1 .. Cur.Len);
                     end if;
                     Next;
                  elsif Cur.Kind = Lex.Tok_Number then
                     if First then
                        Labels := To_Unbounded_String (Cur.Text (1 .. Cur.Len));
                     else
                        Labels := Labels & " | " & Cur.Text (1 .. Cur.Len);
                     end if;
                     Next;
                  else
                     raise O2c_Error with "CASE label expected (line "
                       & Natural'Image (Cur.Line) & ")";
                  end if;
                  First := False;
                  exit when Cur.Kind /= Lex.Tok_Comma;
                  Next;
               end loop;
               Expect (Lex.Tok_Colon, "':' after the CASE labels");
               Next;
               Append_Body ("      when " & To_String (Labels) & " =>");
            end;
         end if;

         --  this alternative's statement sequence
         declare
            Before : constant Natural := Length (Body_Buf);
         begin
            Ctrl_Depth := Ctrl_Depth + 1;
            Statement_Seq (Stop_On_Else => True, Stop_On_Bar => True);
            Ctrl_Depth := Ctrl_Depth - 1;
            if Length (Body_Buf) = Before then
               Append_Body ("         null;");
            end if;
         end;

         if Cur.Kind = Lex.Tok_Bar then
            Next;
         elsif Cur.Kind = Lex.Tok_Else then
            null;                  --  next loop iteration handles ELSE
         elsif Cur.Kind = Lex.Tok_End then
            exit;
         else
            raise O2c_Error with "expected '|', ELSE or END in CASE (line "
              & Natural'Image (Cur.Line) & ")";
         end if;
      end loop;

      Expect (Lex.Tok_End, "'END' closing the CASE");
      Next;
      if not Used_Else then
         Append_Body ("      when others => null;");
      end if;
      Append_Body ("      end case;");
   end Parse_Case;

   procedure Statement_Seq (Stop_On_Else : Boolean := False;
                            Stop_On_Until : Boolean := False;
                            Stop_On_Bar : Boolean := False) is
      Head : String (1 .. 64);
      H_Len : Natural := 0;
      Idx  : Natural;
   begin
      loop
         exit when At_Stop (Stop_On_Else, Stop_On_Until, Stop_On_Bar);

         if Cur.Kind = Lex.Tok_Case then
            Parse_Case;
         elsif Cur.Kind = Lex.Tok_Return then
            if not In_Proc then
               raise O2c_Error with "RETURN only inside procedures (line "
                 & Natural'Image (Cur.Line) & ")";
            end if;
            Next;
            if Cur_Proc_Ret then
               declare
                  V : Expr_Rec := Parse_Expr;
               begin
                  if Cur_Ret_UT /= 0 then
                     if V.Typ /= T_Nil and then
                       (V.Typ /= T_Ptr or else V.Ptr_UT /= Cur_Ret_UT)
                     then
                        raise O2c_Error with "RETURN value type mismatch "
                          & "(line " & Natural'Image (Cur.Line) & ")";
                     end if;
                  elsif V.Typ /= Cur_Ret_Type then
                     raise O2c_Error with "RETURN value type mismatch (line "
                       & Natural'Image (Cur.Line) & ")";
                  end if;
                  Append_Body ("      return " & To_String (V.Text) & ";");
                  if Ctrl_Depth = 0 then
                     Func_Return_Ok := True;
                  end if;
               end;
            else
               if Starts_Expr (Cur.Kind) then
                  raise O2c_Error with "a proper procedure returns no value"
                    & " (line " & Natural'Image (Cur.Line) & ")";
               end if;
               Append_Body ("      return;");
            end if;
         elsif Cur.Kind = Lex.Tok_If then
            Parse_If;
         elsif Cur.Kind = Lex.Tok_While then
            Parse_While;
         elsif Cur.Kind = Lex.Tok_Repeat then
            Parse_Repeat;
         elsif Cur.Kind = Lex.Tok_For then
            Parse_For;
         elsif Cur.Kind = Lex.Tok_Loop then
            Parse_Loop;
         elsif Cur.Kind = Lex.Tok_Exit then
            Parse_Exit;
         elsif Cur.Kind = Lex.Tok_Ident then
            H_Len := Cur.Len;
            Head (1 .. H_Len) := Cur.Text (1 .. H_Len);
            if Eq_No_Case (Head (1 .. H_Len), "NEW") then
               --  NEW(p): allocate the record a POINTER designates (M8).
               --  NEW is a predeclared procedure, recognized here in
               --  statement position like a keyword (case-insensitive).
               Next;                       --  past NEW
               Expect (Lex.Tok_LParen, "'(' after NEW");
               Next;
               if Cur.Kind /= Lex.Tok_Ident then
                  raise O2c_Error with "NEW needs a POINTER variable or "
                    & "pointer field (line " & Natural'Image (Cur.Line)
                    & ")";
               end if;
               declare
                  NId : constant Natural := Find (Cur.Text (1 .. Cur.Len));
                  NNm : constant String := Cur.Text (1 .. Cur.Len);
               begin
                  if NId = 0 or else Syms (NId).Kind /= S_Var
                    or else Syms (NId).UT = 0
                    or else not (UTypes (Syms (NId).UT).Is_Ptr
                                 or else UTypes (Syms (NId).UT).Is_Rec)
                  then
                     raise O2c_Error with "NEW needs a POINTER variable "
                       & "('" & NNm & "' is not one) (line "
                       & Natural'Image (Cur.Line) & ")";
                  end if;
                  Next;             --  past the variable name
                  declare
                     D : Desig := Parse_Rec_Ptr_Chain (NNm, Syms (NId).UT);
                  begin
                     if D.K /= D_Ptr then
                        raise O2c_Error with "NEW needs a POINTER value "
                          & "(line " & Natural'Image (Cur.Line) & ")";
                     end if;
                     Expect (Lex.Tok_RParen, "')' after the NEW argument");
                     Next;
                     Append_Body ("      " & To_String (D.Text) & " := new "
                                  & To_String
                                    (UTypes (UTypes (D.UT).Ptr_Tgt).Name)
                                  & ";");
                  end;
               end;
            else
            Idx := Find (Head (1 .. H_Len));
            Next;
            if Cur.Kind = Lex.Tok_Caret and then Idx /= 0
              and then Syms (Idx).Kind = S_Var
              and then Syms (Idx).UT /= 0
              and then (UTypes (Syms (Idx).UT).Is_Ptr
                        or else UTypes (Syms (Idx).UT).Is_Rec)
            then
               --  deref designator assignment p^.f := e (M8): a scalar
               --  end takes an expression, a pointer end takes a
               --  pointer value or NIL.
               declare
                  D : Desig := Parse_Rec_Ptr_Chain (Head (1 .. H_Len),
                                                    Syms (Idx).UT);
               begin
                  Expect (Lex.Tok_Assign, "':='");
                  Next;
                  if D.K = D_Scalar then
                     if D.Sc = T_Char and then Cur.Kind = Lex.Tok_String
                       and then Cur.Len = 1
                     then
                        Append_Body ("      " & To_String (D.Text) & " := '"
                                     & Cur.Text (1 .. 1) & "';");
                        Next;
                     else
                        declare
                           V : Expr_Rec := Parse_Expr;
                        begin
                           if V.Typ /= D.Sc or else V.Typ = T_Str then
                              raise O2c_Error with "type mismatch assigning "
                                & To_String (D.Text);
                           end if;
                           Append_Body ("      " & To_String (D.Text)
                                        & " := " & To_String (V.Text) & ";");
                        end;
                     end if;
                  else
                     Assign_Pointer (To_String (D.Text), D.UT);
                  end if;
               end;
            elsif Cur.Kind = Lex.Tok_LBracket and then Idx /= 0
              and then Syms (Idx).Kind = S_Var
              and then Syms (Idx).UT /= 0
              and then not UTypes (Syms (Idx).UT).Is_Rec
              and then not UTypes (Syms (Idx).UT).Is_Ptr
            then
               --  array element assignment: a[i] := e
               Next;                --  past '['
               declare
                  Ix : Expr_Rec := Parse_Expr;
                  V  : Expr_Rec;
               begin
                  if Ix.Typ /= T_Int then
                     raise O2c_Error with "array index must be INTEGER";
                  end if;
                  Expect (Lex.Tok_RBracket, "']'");
                  Next;
                  Expect (Lex.Tok_Assign, "':='");
                  Next;
                  if UTypes (Syms (Idx).UT).Elem = T_Char then
                     --  string element: CHAR, Ada index i + 1
                     if Cur.Kind = Lex.Tok_String and then Cur.Len = 1 then
                        Append_Body ("      " & Head (1 .. H_Len) & " ("
                                     & To_String (Ix.Text) & " + 1) := '"
                                     & Cur.Text (1 .. 1) & "';");
                        Next;
                     else
                        V := Parse_Expr;
                        if V.Typ /= T_Char then
                           raise O2c_Error with "string elements are CHAR"
                             & " (assign a character to "
                             & Head (1 .. H_Len) & ")";
                        end if;
                        Append_Body ("      " & Head (1 .. H_Len) & " ("
                                     & To_String (Ix.Text) & " + 1) := "
                                     & To_String (V.Text) & ";");
                     end if;
                  else
                     V := Parse_Expr;
                     if V.Typ /= UTypes (Syms (Idx).UT).Elem then
                        raise O2c_Error with "element type mismatch assigning "
                          & Head (1 .. H_Len);
                     end if;
                     Append_Body ("      " & Head (1 .. H_Len) & " ("
                                  & To_String (Ix.Text) & ") := "
                                  & To_String (V.Text) & ";");
                  end if;
               end;
            elsif Cur.Kind = Lex.Tok_Dot and then Idx /= 0
              and then Syms (Idx).Kind = S_Var
              and then Syms (Idx).UT /= 0
            then
               --  record field assignment: r.f := e (scalar or POINTER
               --  field in M8); other user arrays get an error here.
               declare
                  U     : constant Natural := Syms (Idx).UT;
                  FName : String (1 .. 64);
                  F_Len : Natural;
                  F     : Natural;
                  V     : Expr_Rec;
               begin
                  if UTypes (U).Is_Ptr then
                     raise O2c_Error with "'.' selects a record field; "
                       & "deref the POINTER with '^' first (line "
                       & Natural'Image (Cur.Line) & ")";
                  elsif UTypes (U).Is_Rec then
                     Next;          --  past '.'
                     Expect (Lex.Tok_Ident, "a field name");
                     FName (1 .. Cur.Len) := Cur.Text (1 .. Cur.Len);
                     F_Len := Cur.Len;
                     F := Field_Of (U, FName (1 .. F_Len));
                     if F = 0 then
                        raise O2c_Error with "no field '" & FName (1 .. F_Len)
                          & "' in record " & To_String (UTypes (U).Name);
                     end if;
                     Next;
                     Expect (Lex.Tok_Assign, "':='");
                     Next;
                     if UTypes (U).F (F).UT /= 0 then
                        Assign_Pointer (Head (1 .. H_Len) & "."
                                        & FName (1 .. F_Len),
                                        UTypes (U).F (F).UT);
                     else
                        V := Parse_Expr;
                        if V.Typ /= UTypes (U).F (F).Typ then
                           raise O2c_Error with "field type mismatch assigning "
                             & Head (1 .. H_Len) & "." & FName (1 .. F_Len);
                        end if;
                        Append_Body ("      " & Head (1 .. H_Len) & "."
                                     & FName (1 .. F_Len) & " := "
                                     & To_String (V.Text) & ";");
                     end if;
                  else
                     raise O2c_Error with "array '" & Head (1 .. H_Len)
                       & "' needs an index";
                  end if;
               end;
            elsif Cur.Kind = Lex.Tok_Assign and then Idx /= 0
              and then Syms (Idx).Kind = S_Var
              and then Syms (Idx).UT /= 0
            then
               --  whole record/array copy b := a, or string literal into
               --  an ARRAY OF CHAR variable (padded with NULs)
               declare
                  U  : constant Natural := Syms (Idx).UT;
                  N  : constant Integer := UTypes (U).Arr_Len;
               begin
                  Next;             --  past ':='
                  if UTypes (U).Is_Ptr then
                     --  pointer copy: p := q / p := p^.next / p := NIL
                     Assign_Pointer (Head (1 .. H_Len), U);
                  elsif UTypes (U).Elem = T_Char
                    and then Cur.Kind = Lex.Tok_String
                  then
                     if Cur.Len > N then
                        raise O2c_Error with "string literal too long for "
                          & Head (1 .. H_Len) & " (" & Integer'Image (Cur.Len)
                          & " > " & Integer'Image (N) & ")";
                     end if;
                     if Cur.Len = N then
                        Append_Body ("      " & Head (1 .. H_Len) & " := "
                                     & Ada_String_Literal (Cur.Text (1 .. Cur.Len))
                                     & ";");
                     else
                        Append_Body ("      " & Head (1 .. H_Len) & " := "
                                     & Ada_String_Literal (Cur.Text (1 .. Cur.Len))
                                     & " & String'(1 .. "
                                     & Integer'Image (N - Cur.Len)
                                     & " => ASCII.NUL);");
                     end if;
                     Next;
                  else
                     if Cur.Kind /= Lex.Tok_Ident then
                        raise O2c_Error with "whole-value copy needs a"
                          & " variable of the same type";
                     end if;
                     declare
                        R : Natural := Find (Cur.Text (1 .. Cur.Len));
                     begin
                        if R = 0 or else Syms (R).Kind /= S_Var
                          or else Syms (R).UT /= Syms (Idx).UT
                        then
                           raise O2c_Error with "'" & Cur.Text (1 .. Cur.Len)
                             & "' is not a same-typed variable (copy of "
                             & Head (1 .. H_Len) & ")";
                        end if;
                        Append_Body ("      " & Head (1 .. H_Len) & " := "
                                     & Cur.Text (1 .. Cur.Len) & ";");
                        Next;
                     end;
                  end if;
               end;
            elsif Cur.Kind = Lex.Tok_Dot then
               --  Out.String / Out.Int / Out.Ln
               Next;
               Expect (Lex.Tok_Ident, "a member name after '.'");
               declare
                  Member : constant String := Cur.Text (1 .. Cur.Len);
                  M : Unbounded_String;
                  CArg : Boolean := False;
               begin
                  if Head (1 .. H_Len) /= "Out" then
                     raise O2c_Error with "M3 calls only module Out (found '"
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
                           CArg := A.CStr;
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
                     if Cur.Kind = Lex.Tok_Comma then
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
                        if CArg then
                           Used_CStr := True;
                           Append_Body ("      O2c_Put_CStr (" & To_String (M)
                                        & ");");
                        else
                           Append_Body ("      Aegir_User.Console.Put ("
                                        & To_String (M) & ");");
                        end if;
                     else
                        Append_Body ("      O2c_Put_Int (" & To_String (M)
                                     & ");");
                     end if;
                  else
                     raise O2c_Error with "M3 supports Out.String/Out.Int/"
                       & "Out.Ln only (found Out." & Member & ")";
                  end if;
               end;
            elsif Cur.Kind = Lex.Tok_LParen then
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
                        A : Expr_Rec :=
                          Parse_Actual (Syms (Idx).P (N_A));
                     begin
                        Args (N_A) := A.Text;
                     end;
                     exit when Cur.Kind /= Lex.Tok_Comma;
                     Next;
                  end loop;
                  if N_A /= Syms (Idx).Params then
                     raise O2c_Error with Head (1 .. H_Len) & " expects "
                       & Natural'Image (Syms (Idx).Params)
                       & " argument(s), got " & Natural'Image (N_A);
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
               if Idx = 0 or else Syms (Idx).Kind /= S_Var then
                  raise O2c_Error with "'" & Head (1 .. H_Len)
                    & "' is not a variable (line " & Natural'Image (Cur.Line)
                    & ")";
               end if;
               Next;
               if Syms (Idx).Typ = T_Char
                 and then Cur.Kind = Lex.Tok_String and then Cur.Len = 1
               then
                  Append_Body ("      " & Head (1 .. H_Len) & " := '"
                               & Cur.Text (1 .. 1) & "';");
                  Next;
               else
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
               end if;
            elsif Cur.Kind = Lex.Tok_Colon then
               raise O2c_Error with "unsupported ':' after identifier (line "
                 & Natural'Image (Cur.Line) & ")";
            else
               if Idx = 0 or else Syms (Idx).Kind /= S_Proc
                 or else Syms (Idx).Params /= 0
               then
                  raise O2c_Error with "'" & Head (1 .. H_Len)
                    & "' is not a declared procedure (line "
                    & Natural'Image (Cur.Line) & ")";
               end if;
               Append_Body ("      " & Head (1 .. H_Len) & ";");
            end if;
            end if;            --  close the NEW / regular dispatch split
         else
            raise O2c_Error with "M3 statement expected at line "
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
      N_UT := 0;
      Loop_Depth := 0;
      Loop_N := 0;
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
            Check_No_Pending;
            Next;
            while Cur.Kind = Lex.Tok_Ident loop
               Decl_Var;
            end loop;
         elsif Cur.Kind = Lex.Tok_Type then
            if Seen_Proc then
               raise O2c_Error with "declare CONST/VAR/TYPE before PROCEDUREs"
                 & " (order rule)";
            end if;
            Next;
            while Cur.Kind = Lex.Tok_Ident loop
               Decl_Type;
            end loop;
         elsif Cur.Kind = Lex.Tok_Procedure then
            Next;
            Decl_Procedure;
         else
            raise O2c_Error with "expected CONST/VAR/TYPE/PROCEDURE/BEGIN/END"
              & " at line " & Natural'Image (Cur.Line);
         end if;
      end loop;

      Check_No_Pending;

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
      if Used_CStr then
         S := S & "   procedure O2c_Put_CStr (S : String) is" & ASCII.LF
           & "   begin" & ASCII.LF
           & "      for I in S'Range loop" & ASCII.LF
           & "         if S (I) = ASCII.NUL then" & ASCII.LF
           & "            Aegir_User.Console.Put (S (S'First .. I - 1));"
           & ASCII.LF
           & "            return;" & ASCII.LF
           & "         end if;" & ASCII.LF
           & "      end loop;" & ASCII.LF
           & "      Aegir_User.Console.Put (S);" & ASCII.LF
           & "   end O2c_Put_CStr;" & ASCII.LF;
      end if;
      S := S & To_String (Decl_Buf);
      S := S & "begin" & ASCII.LF;
      S := S & "   Aegir_User.Console.Set_Endpoint (1);" & ASCII.LF;
      S := S & To_String (Body_Buf);
      S := S & "end " & To_String (Mod_Name) & ";" & ASCII.LF;
      return To_String (S);
   end Compile;

end O2c_Compiler;
