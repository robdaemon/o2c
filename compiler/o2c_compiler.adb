with Ada.Strings.Unbounded;
with O2c_Lexer;

package body O2c_Compiler is

   use Ada.Strings.Unbounded;
   use type O2c_Lexer.Token_Kind;

   package Lex renames O2c_Lexer;

   --  T_Ptr and T_Nil are typing sentinels (never reach Ada_Type):
   --  T_Ptr marks a pointer-value operand (Ptr_UT names its pointer
   --  user type), T_Nil marks the NIL literal.
   type EType is (T_Int, T_Bool, T_Str, T_Char, T_Long, T_Set, T_Real,
                  T_Ptr, T_Nil);

   type Expr_Rec is record
      Text   : Unbounded_String;
      Typ    : EType := T_Int;
      CStr   : Boolean := False;   --  whole ARRAY OF CHAR variable value
      Ptr_UT : Natural := 0;       --  pointer user-type index when T_Ptr
      Lit    : Boolean := False;   --  a plain numeric literal (widening)
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
      Is_Ext  : Boolean := False;   --  RECORD (T0) extension (M13)
      Parent  : Natural := 0;       --  parent record UT (when Is_Ext)
      Ptr_Tgt : Natural := 0;       --  record UT a pointer designates
      Pend    : Boolean := False;   --  POINTER TO a not-yet-declared
                                    --  target (buffer its access decl)
      Pend_Nm : Unbounded_String;   --  pending target name (when Pend)
      Arr_Len : Integer := 0;       --  arrays (0 = record or pointer)
      Elem    : EType := T_Int;     --  array element type
      Elem_UT : Natural := 0;       --  array element user type (M16)
      N_F     : Natural := 0;
      F       : UField_Array := (others => <>);
      ExpT    : Boolean := False;   --  export mark on the type (M20)
      Imported : Boolean := False;  --  synthesized from another module (M20)
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
      Open   : Boolean := False;  --  ARRAY OF formal (M12)
   end record;

   type Param_Array is array (1 .. Max_Params) of Param_Rec;

   type Nm_Array is array (1 .. Max_Params) of Unbounded_String;

   type Sym is record
      Kind   : Sym_Kind := S_Var;
      Typ    : EType := T_Int;
      Name   : Unbounded_String;
      Params : Natural := 0;
      Ret    : Boolean := False;   --  procedure is a function (returns Typ)
      UT     : Natural := 0;       --  user type index (0 = scalar Typ)
      Open_Arr : Boolean := False; --  ARRAY OF parameter (M12); Typ = elem
      By_Ref   : Boolean := False; --  formal VAR parameter
      Exp    : Boolean := False;   --  export mark 'name*' (M19)
      P      : Param_Array := (others => <>);
   end record;

   Syms  : array (1 .. Max_Syms) of Sym := (others => <>);
   N_Sym : Natural := 0;

   --  module imports (M19): the builtin Out plus user library modules
   --  provided earlier in a Compile_Multi run.
   Max_Imports : constant := 8;
   type Import_Rec is record
      Name : Unbounded_String;
   end record;
   Imports : array (1 .. Max_Imports) of Import_Rec := (others => <>);
   N_Imp   : Natural := 0;

   --  library modules already compiled in this Compile_Multi run
   Max_Prov : constant := 16;
   Provided : array (1 .. Max_Prov) of Unbounded_String := (others => <>);
   N_Prov   : Natural := 0;

   --  export catalog (M19): the visible symbols of library modules
   --  compiled so far; importers resolve qualified names against it.
   Max_X : constant := 512;
   type X_Entry is record
      Owner  : Unbounded_String;
      Name   : Unbounded_String;
      Kind   : Sym_Kind := S_Const;
      Typ    : EType := T_Int;      --  scalar type of const/var/function
      Params : Natural := 0;
      Ret    : Boolean := False;
      P      : Param_Array := (others => <>);
      --  M20b: qualified exported-type names of formal parameters and
      --  of a function result ("" when the slot is scalar).
      P_Nm   : Nm_Array := (others => <>);
      Ret_Nm : Unbounded_String;
   end record;
   Xs  : array (1 .. Max_X) of X_Entry := (others => <>);
   N_X : Natural := 0;

   Pkg_Mode   : Boolean := False;   --  compiling a library module
   Multi_Ok   : Boolean := False;   --  library imports are available
   Spec_Buf   : Unbounded_String;   --  package spec text (exports)
   Spec_Decl  : Boolean := False;   --  route Append_Decl to Spec_Buf (M20)
   Used_Console : Boolean := False; --  module emits Console calls

   --  exported type catalog (M20): the visible TYPE declarations of
   --  library modules.  References between types are stored by name
   --  (Owner.Type) because each module owns its own UTypes table.
   Max_XT : constant := 64;
   type XT_Field is record
      Name   : Unbounded_String;
      Typ    : EType := T_Int;      --  scalar field type (UT_Nm = "")
      UT_Nm  : Unbounded_String;    --  qualified user type name, if any
   end record;
   type XT_Field_Arr is array (1 .. 16) of XT_Field;
   type XT_Entry is record
      Owner   : Unbounded_String;
      Name    : Unbounded_String;
      Is_Rec  : Boolean := False;
      Is_Ptr  : Boolean := False;
      Is_Ext  : Boolean := False;
      Ptr_Nm  : Unbounded_String;   --  qualified POINTER TO target
      Par_Nm  : Unbounded_String;   --  qualified RECORD (Parent)
      N_F     : Natural := 0;
      F       : XT_Field_Arr := (others => <>);
   end record;
   XT_Tab : array (1 .. Max_XT) of XT_Entry := (others => <>);
   N_XT   : Natural := 0;

   --  exported method catalog (M20c): type-bound procedures exported
   --  by library modules, keyed by bound record name + method name.
   Max_XM : constant := 128;
   type XM_Entry is record
      Owner  : Unbounded_String;
      MName  : Unbounded_String;
      RecN   : Unbounded_String;   --  bare exported record type name
      Ret    : Boolean := False;
      Typ    : EType := T_Int;     --  scalar result type
      Ret_Nm : Unbounded_String;   --  qualified exported POINTER result
      Params : Natural := 0;       --  extra arguments (receiver excluded)
      P      : Param_Array := (others => <>);
      P_Nm   : Nm_Array := (others => <>);
   end record;
   XMs : array (1 .. Max_XM) of XM_Entry := (others => <>);
   N_XM : Natural := 0;

   --  forward (body defined with the other M20 import machinery)
   function Import_Type (Owner, Mem : String) return Natural;

   --  type-bound procedures (M13): method name, the record type it is
   --  bound to, and its S_Proc symbol (params 1.. include the receiver).
   Max_Bound : constant := 64;
   type Bound_Rec is record
      Name   : Unbounded_String;
      RecUT  : Natural := 0;
      SymIdx : Natural := 0;
   end record;
   Bounds : array (1 .. Max_Bound) of Bound_Rec := (others => <>);
   N_Bound : Natural := 0;

   --  receiver context while parsing a type-bound procedure
   Recv_UT  : Natural := 0;      --  record type the method binds to
   Recv_Var : Boolean := False;  --  VAR receiver
   Recv_Nm  : Unbounded_String;  --  receiver variable name

   --  active WITH guards (M13): variable name -> guard record type
   Max_Guards : constant := 32;
   G_Nm : array (1 .. Max_Guards) of Unbounded_String;
   G_Rec : array (1 .. Max_Guards) of Natural := (others => 0);
   G_N   : Natural := 0;

   --  method-function dispatchers (M15): one per (method, bound record),
   --  spec emitted at the method declaration, body after all methods.
   Max_Dsp : constant := 32;
   type Dsp_Rec is record
      MName : Unbounded_String;
      BRec  : Natural := 0;
      SymIdx : Natural := 0;   --  impl S_Proc (params 1.. incl receiver)
   end record;
   Dsps : array (1 .. Max_Dsp) of Dsp_Rec := (others => <>);
   N_Dsp : Natural := 0;

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
   Used_Int_Arr  : Boolean := False;  --  need O2c_Int_Arr base (M12)
   Used_Bool_Arr : Boolean := False;  --  need O2c_Bool_Arr base (M12)
   Used_Set      : Boolean := False;  --  need O2c_Set type + Interfaces
   Used_Real     : Boolean := False;  --  need O2c_Put_Real helper (M18)
   Loop_Depth : Natural := 0;      --  open LOOP statements (EXIT target)
   Loop_N     : Natural := 0;      --  LOOP counter for generated labels
   Loop_Lbl   : array (1 .. 64) of Unbounded_String;  --  per-depth label

   procedure Append_Decl (S : String) is
   begin
      if Spec_Decl then
         Spec_Buf := Spec_Buf & S & ASCII.LF;
      else
         Decl_Buf := Decl_Buf & S & ASCII.LF;
      end if;
   end Append_Decl;

   procedure Append_Body (S : String) is
   begin
      Body_Buf := Body_Buf & S & ASCII.LF;
   end Append_Body;

   procedure Append_Spec (S : String) is
   begin
      Spec_Buf := Spec_Buf & S & ASCII.LF;
   end Append_Spec;

   function Is_Provided (Nm : String) return Boolean is
   begin
      for I in 1 .. N_Prov loop
         if To_String (Provided (I)) = Nm then
            return True;
         end if;
      end loop;
      return False;
   end Is_Provided;

   --  True when Nm is one of this module's user library imports (Out
   --  keeps its legacy special-cased handling).
   function Imported_Mod (Nm : String) return Boolean is
   begin
      if Nm = "Out" then
         return False;
      end if;
      for I in 1 .. N_Imp loop
         if To_String (Imports (I).Name) = Nm then
            return True;
         end if;
      end loop;
      return False;
   end Imported_Mod;

   --  Catalog index of the exported member Mem of library module Mod.
   function Find_X (Owner : String; Mem : String) return Natural is
   begin
      for I in 1 .. N_X loop
         if To_String (Xs (I).Owner) = Owner
           and then To_String (Xs (I).Name) = Mem
         then
            return I;
         end if;
      end loop;
      return 0;
   end Find_X;

   procedure X_Add (Owner : String; E : X_Entry) is
   begin
      N_X := N_X + 1;
      if N_X > Xs'Last then
         raise O2c_Error with "too many exported symbols";
      end if;
      Xs (N_X) := E;
      Xs (N_X).Owner := To_Unbounded_String (Owner);
   end X_Add;

   --  Split a qualified "Owner.Member" name (first '.').
   function Q_Dot (Q : String) return Natural is
   begin
      for C in Q'Range loop
         if Q (C) = '.' then
            return C;
         end if;
      end loop;
      raise O2c_Error with "internal: expected a qualified name in the "
        & "export catalog";
   end Q_Dot;

   function Q_Owner (Q : String) return String is
   begin
      return Q (Q'First .. Q_Dot (Q) - 1);
   end Q_Owner;

   function Q_Mem (Q : String) return String is
      D : constant Natural := Q_Dot (Q);
   begin
      return Q (D + 1 .. Q'Last);
   end Q_Mem;

   --  M20b call site: the formal for catalog argument XI slot I.  User
   --  typed formals import the exported type into this module, so
   --  Parse_Actual can type-check arguments against the local shape.
   function X_Formal (XI, I : Natural) return Param_Rec is
      F : Param_Rec := Xs (XI).P (I);
   begin
      if Length (Xs (XI).P_Nm (I)) > 0 then
         declare
            Q : constant String := To_String (Xs (XI).P_Nm (I));
         begin
            F.UT := Import_Type (Q_Owner (Q), Q_Mem (Q));
            F.Typ := T_Int;
            F.Open := False;
         end;
      end if;
      return F;
   end X_Formal;

   --  M20b: import the exported POINTER result type of catalog
   --  function XI (0 when the result is scalar).
   function X_Ret_UT (XI : Natural) return Natural is
   begin
      if Length (Xs (XI).Ret_Nm) > 0 then
         declare
            Q : constant String := To_String (Xs (XI).Ret_Nm);
         begin
            return Import_Type (Q_Owner (Q), Q_Mem (Q));
         end;
      end if;
      return 0;
   end X_Ret_UT;

   --  M20c import helpers: resolve an exported type-bound method on an
   --  imported record chain (deepest bound first) and import a method
   --  argument's type.
   function Short_Nm (Nm : String) return String is
   begin
      for C in Nm'Range loop
         if Nm (C) = '.' then
            return Nm (C + 1 .. Nm'Last);
         end if;
      end loop;
      return Nm;
   end Short_Nm;

   function UT_Owner (U : Natural) return String is
      N : constant String := To_String (UTypes (U).Name);
   begin
      for C in N'Range loop
         if N (C) = '.' then
            return N (N'First .. C - 1);
         end if;
      end loop;
      return To_String (Mod_Name);
   end UT_Owner;

   function XM_Bound (Owner : String; Rec : Natural;
                      MName : String) return Natural is
      U : Natural := Rec;
   begin
      while U /= 0 loop
         for I in 1 .. N_XM loop
            if To_String (XMs (I).Owner) = Owner
              and then Short_Nm (To_String (UTypes (U).Name)) =
                To_String (XMs (I).RecN)
              and then To_String (XMs (I).MName) = MName
            then
               return I;
            end if;
         end loop;
         U := UTypes (U).Parent;
      end loop;
      return 0;
   end XM_Bound;

   function XM_Formal (XMI, I : Natural) return Param_Rec is
      F : Param_Rec := XMs (XMI).P (I);
   begin
      if Length (XMs (XMI).P_Nm (I)) > 0 then
         declare
            Q : constant String := To_String (XMs (XMI).P_Nm (I));
         begin
            F.UT := Import_Type (Q_Owner (Q), Q_Mem (Q));
            F.Typ := T_Int;
            F.Open := False;
         end;
      end if;
      return F;
   end XM_Formal;

   --  M19: exportable scalar kinds.  SET stays module-private because
   --  each Ada unit declares its own O2c_Set type; user types and open
   --  arrays need a shared package type and are an M20 item.
   function Scalar_Exportable (T : EType) return Boolean is
   begin
      return T = T_Int or else T = T_Long or else T = T_Real
        or else T = T_Char or else T = T_Bool;
   end Scalar_Exportable;

   function Lower (S : String) return String is
      R : String (S'Range);
   begin
      for I in S'Range loop
         R (I) := (if S (I) in 'A' .. 'Z'
                   then Character'Val (Character'Pos (S (I)) + 32)
                   else S (I));
      end loop;
      return R;
   end Lower;

   function QName (Owner, Mem : String) return String is
   begin
      return Owner & "." & Mem;
   end QName;

   function XT_Find (Owner : String; Mem : String) return Natural is
   begin
      for I in 1 .. N_XT loop
         if To_String (XT_Tab (I).Owner) = Owner
           and then To_String (XT_Tab (I).Name) = Mem
         then
            return I;
         end if;
      end loop;
      return 0;
   end XT_Find;

   --  M20a: register and validate the exported TYPE declarations of a
   --  library module after it has been parsed.  Exported shapes may
   --  reference scalars (INTEGER/LONGINT/REAL/CHAR/BOOLEAN) and other
   --  exported records/pointers of the same module only; arrays, SET
   --  fields, non-exported shapes and cross-module composition are M20b.
   procedure Capture_Types is
   begin
      for U in 1 .. N_UT loop
         if not UTypes (U).ExpT then
            null;
         elsif UTypes (U).Is_Ptr then
            if UTypes (U).Ptr_Tgt = 0
              or else not UTypes (UTypes (U).Ptr_Tgt).ExpT
              or else not UTypes (UTypes (U).Ptr_Tgt).Is_Rec
            then
               raise O2c_Error with "exported POINTER TO type '"
                 & To_String (UTypes (U).Name)
                 & "' must designate an exported RECORD of the same module "
                 & "(M20a)";
            end if;
         elsif UTypes (U).Is_Rec then
            if UTypes (U).Is_Ext
              and then (UTypes (U).Parent = 0
                        or else not UTypes (UTypes (U).Parent).ExpT)
            then
               raise O2c_Error with "exported extension type '"
                 & To_String (UTypes (U).Name)
                 & "' must extend an exported RECORD of the same module "
                 & "(M20a)";
            end if;
            for F in 1 .. UTypes (U).N_F loop
               declare
                  Fld : UField renames UTypes (U).F (F);
               begin
                  if Fld.UT /= 0 then
                     if not (UTypes (Fld.UT).Is_Rec
                             or else UTypes (Fld.UT).Is_Ptr)
                       or else not UTypes (Fld.UT).ExpT
                     then
                        raise O2c_Error with "exported RECORD '"
                          & To_String (UTypes (U).Name)
                          & "': field '" & To_String (Fld.Name)
                          & "' must be scalar or an exported RECORD/POINTER "
                          & "of the same module (arrays are M20b)";
                     end if;
                  elsif Fld.Typ = T_Set then
                     raise O2c_Error with "exported RECORD '"
                       & To_String (UTypes (U).Name)
                       & "': SET fields are not exportable (M20a)";
                  end if;
               end;
            end loop;
         end if;
      end loop;
      --  register the shapes (references as qualified names)
      for U in 1 .. N_UT loop
         if UTypes (U).ExpT then
            N_XT := N_XT + 1;
            if N_XT > XT_Tab'Last then
               raise O2c_Error with "too many exported types";
            end if;
            XT_Tab (N_XT) :=
              (Owner => To_Unbounded_String (To_String (Mod_Name)),
               Name  => UTypes (U).Name,
               Is_Rec => UTypes (U).Is_Rec,
               Is_Ptr => UTypes (U).Is_Ptr,
               Is_Ext => UTypes (U).Is_Ext,
               others => <>);
            if UTypes (U).Is_Ptr then
               XT_Tab (N_XT).Ptr_Nm := To_Unbounded_String
                 (QName (To_String (Mod_Name),
                         To_String (UTypes (UTypes (U).Ptr_Tgt).Name)));
            end if;
            if UTypes (U).Is_Ext then
               XT_Tab (N_XT).Par_Nm := To_Unbounded_String
                 (QName (To_String (Mod_Name),
                         To_String (UTypes (UTypes (U).Parent).Name)));
            end if;
            if UTypes (U).Is_Rec then
               XT_Tab (N_XT).N_F := UTypes (U).N_F;
               for F in 1 .. UTypes (U).N_F loop
                  declare
                     Fld : UField renames UTypes (U).F (F);
                  begin
                     XT_Tab (N_XT).F (F).Name := Fld.Name;
                     if Fld.UT /= 0 then
                        XT_Tab (N_XT).F (F).UT_Nm := To_Unbounded_String
                          (QName (To_String (Mod_Name),
                                  To_String (UTypes (Fld.UT).Name)));
                     else
                        XT_Tab (N_XT).F (F).Typ := Fld.Typ;
                     end if;
                  end;
               end loop;
            end if;
         end if;
      end loop;
   end Capture_Types;

   --  M20a importer side: synthesize the exported types of a library
   --  module into this module's UTypes table (qualified Ada names), so
   --  the designator engine, NEW and value initialisation behave like
   --  local types.  Two passes: stubs first (cycles like Node ->
   --  NodeDesc -> Node resolve), then shapes.
   function Import_Type (Owner, Mem : String) return Natural is
      function UT_By_Name (Nm : String) return Natural is
      begin
         for U in 1 .. N_UT loop
            if UTypes (U).Imported
              and then To_String (UTypes (U).Name) = Nm
            then
               return U;
            end if;
         end loop;
         return 0;
      end UT_By_Name;

      Idx : array (1 .. Max_XT) of Natural := (others => 0);
      Nn  : Natural := 0;
      Map : array (1 .. Max_XT) of Natural := (others => 0);
   begin
      if UT_By_Name (QName (Owner, Mem)) /= 0 then
         return UT_By_Name (QName (Owner, Mem));   --  already imported
      end if;
      if XT_Find (Owner, Mem) = 0 then
         raise O2c_Error with "'" & QName (Owner, Mem)
           & "' is not an exported TYPE of module " & Owner;
      end if;
      for X in 1 .. N_XT loop
         if To_String (XT_Tab (X).Owner) = Owner then
            Nn := Nn + 1;
            Idx (Nn) := X;
         end if;
      end loop;
      for J in 1 .. Nn loop
         N_UT := N_UT + 1;
         if N_UT > UTypes'Last then
            raise O2c_Error with "too many type declarations "
              & "(imported types)";
         end if;
         Map (Idx (J)) := N_UT;
         UTypes (N_UT) :=
           (Name => To_Unbounded_String
              (QName (Owner, To_String (XT_Tab (Idx (J)).Name))),
            Is_Rec  => XT_Tab (Idx (J)).Is_Rec,
            Is_Ptr  => XT_Tab (Idx (J)).Is_Ptr,
            Is_Ext  => XT_Tab (Idx (J)).Is_Ext,
            Imported => True, others => <>);
      end loop;
      for J in 1 .. Nn loop
         declare
            X  : constant Natural := Idx (J);
            U  : constant Natural := Map (X);
         begin
            if XT_Tab (X).Is_Ptr then
               UTypes (U).Ptr_Tgt :=
                 UT_By_Name (To_String (XT_Tab (X).Ptr_Nm));
            end if;
            if XT_Tab (X).Is_Ext then
               UTypes (U).Parent :=
                 UT_By_Name (To_String (XT_Tab (X).Par_Nm));
            end if;
            if XT_Tab (X).Is_Rec then
               UTypes (U).N_F := XT_Tab (X).N_F;
               for F in 1 .. XT_Tab (X).N_F loop
                  UTypes (U).F (F) :=
                    (Name => XT_Tab (X).F (F).Name,
                     Typ => XT_Tab (X).F (F).Typ,
                     UT => (if Length (XT_Tab (X).F (F).UT_Nm) = 0
                            then 0
                            else UT_By_Name
                              (To_String (XT_Tab (X).F (F).UT_Nm))));
               end loop;
            end if;
         end;
      end loop;
      return UT_By_Name (QName (Owner, Mem));
   end Import_Type;



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

   --  Find a record field across the extension chain (M13): searches
   --  UT's own fields then its parents.  Returns the index within the
   --  declaring record and that record's UT in Owner (0 when absent).
   function Field_Of (UT : Natural; Name : String;
                      Owner : out Natural) return Natural is
      U : Natural := UT;
   begin
      while U /= 0 loop
         for I in 1 .. UTypes (U).N_F loop
            if To_String (UTypes (U).F (I).Name) = Name then
               Owner := U;
               return I;
            end if;
         end loop;
         U := UTypes (U).Parent;    --  walk the extension chain
      end loop;
      Owner := 0;
      return 0;
   end Field_Of;

   --  True when record type T is Anc or a (direct/indirect) extension of
   --  it; used for pointer widening (M13).
   function Rec_Descends (T : Natural; Anc : Natural) return Boolean is
      U : Natural := T;
   begin
      while U /= 0 loop
         if U = Anc then
            return True;
         end if;
         U := UTypes (U).Parent;
      end loop;
      return False;
   end Rec_Descends;

   function Rec_Depth (UT : Natural) return Natural is
      D : Natural := 0;
      U : Natural := UT;
   begin
      while U /= 0 loop
         D := D + 1;
         U := UTypes (U).Parent;
      end loop;
      return D;
   end Rec_Depth;

   --  Nearest type-bound method named Name visible on record type UT:
   --  searches UT then its ancestors (M13); returns a Bounds index.
   function Bound_Find (UT : Natural; Name : String) return Natural is
      U : Natural := UT;
   begin
      while U /= 0 loop
         for I in 1 .. N_Bound loop
            if Bounds (I).RecUT = U
              and then To_String (Bounds (I).Name) = Name
            then
               return I;
            end if;
         end loop;
         U := UTypes (U).Parent;
      end loop;
      return 0;
   end Bound_Find;

   function Method_Impl_Name (Name : String; UT : Natural) return String is
   begin
      return Name & "_O2c_" & To_String (UTypes (UT).Name);
   end Method_Impl_Name;

   function Dsp_Name (Name : String; Rec : Natural) return String is
   begin
      return Name & "_Disp_O2c_" & To_String (UTypes (Rec).Name);
   end Dsp_Name;

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
         when T_Long => return "Long_Integer";
         when T_Set  => return "O2c_Set";
         when T_Real => return "Float";
         when T_Ptr | T_Nil =>
            raise O2c_Error
              with "internal: Ada_Type on a pointer/NIL typing sentinel";
      end case;
   end Ada_Type;

   --  Ada type name of a formal parameter (mirrors Formal_Ada_Type).
   function P_Ada_Type (P : Param_Rec) return String is
   begin
      if P.Open then
         if P.Typ = T_Char then
            return "String";
         elsif P.Typ = T_Int then
            return "O2c_Int_Arr";
         else
            return "O2c_Bool_Arr";
         end if;
      elsif P.UT /= 0 then
         return To_String (UTypes (P.UT).Name);
      else
         return Ada_Type (P.Typ);
      end if;
   end P_Ada_Type;

   --  Dispatcher function header for method function (M15): the
   --  receiver is the class-wide view of the bound record B, extra
   --  parameters mirror the method implementation.
   function Dsp_Hdr (DN : String; B : Natural; SIdx : Natural) return String is
      S : Sym renames Syms (SIdx);
      H : Unbounded_String;
   begin
      H := H & "function " & Dsp_Name (DN, B) & " (";
      for I in 1 .. S.Params loop
         if I > 1 then
            H := H & "; ";
         end if;
         H := H & To_String (S.P (I).Name)
           & (if S.P (I).By_Ref then " : in out " else " : ")
           & (if I = 1 then To_String (UTypes (B).Name) & "'Class"
              else P_Ada_Type (S.P (I)));
      end loop;
      H := H & ") return "
        & (if S.UT /= 0 then To_String (UTypes (S.UT).Name)
           else Ada_Type (S.Typ));
      return To_String (H);
   end Dsp_Hdr;

   --  Procedure-method dispatcher header (M20c): receiver is the
   --  class-wide view of bound record B; extra parameters mirror the
   --  method implementation.  Mirrors Dsp_Hdr for procedure methods.
   function Dsp_Hdr_P (DN : String; B : Natural; SIdx : Natural)
                       return String is
      S : Sym renames Syms (SIdx);
      H : Unbounded_String;
   begin
      H := H & "procedure " & Dsp_Name (DN, B) & " (";
      for I in 1 .. S.Params loop
         if I > 1 then
            H := H & "; ";
         end if;
         H := H & To_String (S.P (I).Name)
           & (if S.P (I).By_Ref then " : in out " else " : ")
           & (if I = 1 then To_String (UTypes (B).Name) & "'Class"
              else P_Ada_Type (S.P (I)));
      end loop;
      H := H & ")";
      return To_String (H);
   end Dsp_Hdr_P;

   --  Emit the bodies of all method-function dispatchers (M15).  Run
   --  after every method is known, so each chain covers every override
   --  in the bound record's subtree (deepest first).
   procedure Emit_Dsp_Bodies is
   begin
      for D in 1 .. N_Dsp loop
         declare
            SIdx : constant Natural := Dsps (D).SymIdx;
            DN   : constant String := To_String (Dsps (D).MName);
            B    : constant Natural := Dsps (D).BRec;
            Rcvr : constant String :=
              To_String (Syms (SIdx).P (1).Name);
            ArgN : array (1 .. Max_Params) of Unbounded_String;
            NArg : Natural := Syms (SIdx).Params;
            ArgL : Unbounded_String;
            Cand : array (1 .. Max_Bound) of Natural := (others => 0);
            N_C  : Natural := 0;
         begin
            --  argument names (params 2.., passed straight through)
            for I in 2 .. NArg loop
               ArgN (I) := Syms (SIdx).P (I).Name;
               if I > 2 then
                  ArgL := ArgL & ", ";
               end if;
               ArgL := ArgL & ArgN (I);
            end loop;
            --  overriding descendants of B, deepest first
            for X in 1 .. N_UT loop
               if UTypes (X).Is_Rec and then X /= B
                 and then Rec_Descends (X, B)
               then
                  for Bd in 1 .. N_Bound loop
                     if Bounds (Bd).RecUT = X
                       and then To_String (Bounds (Bd).Name) = DN
                     then
                        declare
                           Pos : Positive := N_C + 1;
                        begin
                           while Pos > 1 and then
                             Rec_Depth (X) > Rec_Depth (Cand (Pos - 1))
                           loop
                              Cand (Pos) := Cand (Pos - 1);
                              Pos := Pos - 1;
                           end loop;
                           Cand (Pos) := X;
                        end;
                        N_C := N_C + 1;
                     end if;
                  end loop;
               end if;
            end loop;
            Append_Decl ("   " & Dsp_Hdr (DN, B, SIdx) & " is");
            Append_Decl ("   begin");
            if N_C > 0 then
               for I in 1 .. N_C loop
                  Append_Decl ("      if " & Rcvr & " in "
                               & To_String (UTypes (Cand (I)).Name)
                               & "'Class then");
                  Append_Decl ("         return "
                               & Method_Impl_Name (DN, Cand (I)) & " ("
                               & To_String (UTypes (Cand (I)).Name) & " ("
                               & Rcvr & ")"
                               & (if NArg > 1
                                  then ", " & To_String (ArgL)
                                  else "")
                               & ");");
               end loop;
               Append_Decl ("      else");
            end if;
            Append_Decl ("         return " & Method_Impl_Name (DN, B)
                         & " (" & To_String (UTypes (B).Name) & " (" & Rcvr
                         & ")"
                         & (if NArg > 1 then ", " & To_String (ArgL) else "")
                         & ");");
            if N_C > 0 then
               Append_Decl ("      end if;");
            end if;
            Append_Decl ("   end " & Dsp_Name (DN, B) & ";");
         end;
      end loop;
   end Emit_Dsp_Bodies;

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
      elsif Eq_No_Case (Name, "LONGINT") then
         return T_Long;
      elsif Eq_No_Case (Name, "SET") then
         return T_Set;
      elsif Eq_No_Case (Name, "REAL") then
         return T_Real;
      end if;
      return T_Str;               --  sentinel: not a builtin scalar
   end Builtin_Type_Of;

   function Scalar_Init (T : EType) return String is
   begin
      case T is
         when T_Int | T_Long | T_Set => return "0";
         when T_Real => return "0.0";
         when T_Char => return "ASCII.NUL";
         when T_Bool => return "False";
         when others =>
            raise O2c_Error with "internal: Scalar_Init on a non-scalar";
      end case;
   end Scalar_Init;

   --  Recursive default value for a whole value of user type UT (M16):
   --  pointers default to null, records to a full named aggregate
   --  (ancestors first, every component defaulted), arrays to
   --  (others => <element default>) at any nesting depth.
   function Value_Init (UT : Natural) return String is
      function Field_Seq (U : Natural) return String is
         S : Unbounded_String;
      begin
         if U /= 0 then
            S := S & Field_Seq (UTypes (U).Parent);
            for F in 1 .. UTypes (U).N_F loop
               if Length (S) > 0 then
                  S := S & ", ";
               end if;
               S := S & To_String (UTypes (U).F (F).Name) & " => "
                 & (if UTypes (U).F (F).UT /= 0
                    then Value_Init (UTypes (U).F (F).UT)
                    else Scalar_Init (UTypes (U).F (F).Typ));
            end loop;
         end if;
         return To_String (S);
      end Field_Seq;
   begin
      if UTypes (UT).Is_Ptr then
         return "null";
      elsif UTypes (UT).Is_Rec then
         return "(" & Field_Seq (UT) & ")";
      elsif UTypes (UT).Elem_UT /= 0 then
         return "(others => " & Value_Init (UTypes (UT).Elem_UT) & ")";
      else
         return "(others => " & Scalar_Init (UTypes (UT).Elem) & ")";
      end if;
   end Value_Init;

   function Field_Init (F : UField) return String is
   begin
      if F.UT /= 0 then
         return Value_Init (F.UT);   --  record/array/pointer field default
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

   type Desig_Kind is (D_Scalar, D_Ptr, D_Str);

   type Desig is record
      Text : Unbounded_String;
      K    : Desig_Kind := D_Scalar;
      Sc   : EType := T_Int;      --  scalar type when D_Scalar
      UT   : Natural := 0;        --  pointer user type when D_Ptr
   end record;

   type VK_Kind is (V_Rec, V_Ptr, V_Arr);

   --  Parse the designator suffix after a user-type base variable
   --  (name consumed; Cur is the first token after it).  Walks a chain
   --  of '.field', '^' deref and '[index]' selectors over record,
   --  pointer and array values (M16), returning the final value: a
   --  scalar (D_Scalar), a pointer (D_Ptr) or a whole ARRAY OF CHAR
   --  value (D_Str).  Ada text drops '^' (auto-deref) and turns
   --  p^.next^.v into p.next.v; char-array indexing adds 1 (Ada
   --  String is 1-based).  Bare pointer variables are valid D_Ptr
   --  operands (p = NIL / whole-pointer copies).
   function Parse_Rec_Ptr_Chain (Base_Name : String;
                                 Base_UT   : Natural)
     return Desig
   is
      D  : Desig;
      VK : VK_Kind;
      UT : Natural := Base_UT;
   begin
      D.Text := To_Unbounded_String (Base_Name);
      if UTypes (UT).Is_Ptr then
         VK := V_Ptr;
      elsif UTypes (UT).Is_Rec then
         VK := V_Rec;
      else
         VK := V_Arr;
      end if;
      --  WITH guard (M13): a guarded pointer variable dereferences to
      --  its guard record type, emitted through a view conversion
      --  (only when a member selector actually follows).
      if VK = V_Ptr and then (Cur.Kind = Lex.Tok_Caret
                              or else Cur.Kind = Lex.Tok_Dot)
      then
         for Gi in 1 .. G_N loop
            if To_String (G_Nm (Gi)) = Base_Name then
               VK := V_Rec;
               UT := G_Rec (Gi);
               D.Text := To_Unbounded_String (To_String (UTypes (UT).Name)
                                              & " (" & Base_Name & ".all)");
               if Cur.Kind = Lex.Tok_Caret then
                  Next;              --  the guard supplies the deref
               end if;
               exit;
            end if;
         end loop;
      end if;
      loop
         if Cur.Kind = Lex.Tok_Caret then
            if VK /= V_Ptr then
               raise O2c_Error with "'^' needs a POINTER operand (line "
                 & Natural'Image (Cur.Line) & ")";
            end if;
            Next;
            VK := V_Rec;
            UT := UTypes (UT).Ptr_Tgt;
            if UT = 0 then
               raise O2c_Error with "internal: deref of an unresolved "
                 & "POINTER TO (line " & Natural'Image (Cur.Line) & ")";
            end if;
         elsif Cur.Kind = Lex.Tok_Dot then
            if VK /= V_Rec then
               if VK = V_Ptr then
                  raise O2c_Error with "'.' selects a record field; deref "
                    & "the POINTER with '^' first (line "
                    & Natural'Image (Cur.Line) & ")";
               end if;
               raise O2c_Error with "'.' needs a RECORD value (line "
                 & Natural'Image (Cur.Line) & ")";
            end if;
            Next;
            Expect (Lex.Tok_Ident, "a field name");
            declare
               FO : Natural;
               F  : constant Natural :=
                 Field_Of (UT, Cur.Text (1 .. Cur.Len), FO);
            begin
               if F = 0 then
                  raise O2c_Error with "no field '" & Cur.Text (1 .. Cur.Len)
                    & "' in record " & To_String (UTypes (UT).Name);
               end if;
               D.Text := D.Text & "." & To_String (UTypes (FO).F (F).Name);
               if UTypes (FO).F (F).UT = 0 then
                  D.K := D_Scalar;
                  D.Sc := UTypes (FO).F (F).Typ;
                  Next;           --  past the field name
                  return D;
               end if;
               UT := UTypes (FO).F (F).UT;
               if UTypes (UT).Is_Ptr then
                  VK := V_Ptr;
               elsif UTypes (UT).Is_Rec then
                  VK := V_Rec;
               else
                  VK := V_Arr;
               end if;
               Next;              --  past the field name
            end;
         elsif Cur.Kind = Lex.Tok_LBracket then
            if VK /= V_Arr then
               raise O2c_Error with "'[' needs an ARRAY value (line "
                 & Natural'Image (Cur.Line) & ")";
            end if;
            Next;                --  past '['
            declare
               Ix : Expr_Rec := Parse_Expr;
            begin
               if Ix.Typ /= T_Int then
                  raise O2c_Error with "array index must be INTEGER (line "
                    & Natural'Image (Cur.Line) & ")";
               end if;
               Expect (Lex.Tok_RBracket, "']'");
               Next;
               if UTypes (UT).Elem_UT /= 0 then
                  --  element is a user type: keep chaining on it
                  D.Text := D.Text & " (" & To_String (Ix.Text) & ")";
                  UT := UTypes (UT).Elem_UT;
                  if UTypes (UT).Is_Ptr then
                     VK := V_Ptr;
                  elsif UTypes (UT).Is_Rec then
                     VK := V_Rec;
                  else
                     VK := V_Arr;
                  end if;
               elsif UTypes (UT).Elem = T_Char then
                  --  char array (Ada String, 1-based)
                  D.Text := D.Text & " (" & To_String (Ix.Text) & " + 1)";
                  D.K := D_Scalar;
                  D.Sc := T_Char;
                  return D;
               else
                  D.Text := D.Text & " (" & To_String (Ix.Text) & ")";
                  D.K := D_Scalar;
                  D.Sc := UTypes (UT).Elem;
                  return D;
               end if;
            end;
         else
            exit;
         end if;
      end loop;
      if VK = V_Ptr then
         D.K := D_Ptr;
         D.UT := UT;
         return D;
      end if;
      if VK = V_Arr and then UTypes (UT).Elem = T_Char then
         D.K := D_Str;
         return D;
      end if;
      if VK = V_Arr then
         raise O2c_Error with "an array value needs an index here (line "
           & Natural'Image (Cur.Line) & ")";
      end if;
      raise O2c_Error with "a record value needs '.field' here (line "
        & Natural'Image (Cur.Line) & ")";
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
      if Formal.Open then
         --  ARRAY OF actual (M12): a string literal (value CHAR formals
         --  only) or an array variable whose element type matches.
         if Formal.Typ = T_Char and then not Formal.By_Ref
           and then Cur.Kind = Lex.Tok_String
         then
            A := Parse_Expr;       --  string literal actual
            return A;
         end if;
         if Cur.Kind /= Lex.Tok_Ident then
            raise O2c_Error with "an array argument expected for an ARRAY "
              & "OF parameter (line " & Natural'Image (Cur.Line) & ")";
         end if;
         declare
            Id : constant Natural := Find (Cur.Text (1 .. Cur.Len));
         begin
            if Id = 0 or else Syms (Id).Kind /= S_Var
              or else not ((Syms (Id).UT /= 0
                            and then not UTypes (Syms (Id).UT).Is_Rec
                            and then not UTypes (Syms (Id).UT).Is_Ptr)
                           or else Syms (Id).Open_Arr)
            then
               raise O2c_Error with "'" & Cur.Text (1 .. Cur.Len)
                 & "' is not an array variable (line "
                 & Natural'Image (Cur.Line) & ")";
            end if;
            declare
               Elem : constant EType :=
                 (if Syms (Id).UT /= 0
                  then UTypes (Syms (Id).UT).Elem
                  else Syms (Id).Typ);
            begin
               if Elem /= Formal.Typ then
                  raise O2c_Error with "array element type mismatch for an "
                    & "ARRAY OF argument (line "
                    & Natural'Image (Cur.Line) & ")";
               end if;
            end;
            if Formal.By_Ref and then Syms (Id).Open_Arr
              and then not Syms (Id).By_Ref
            then
               raise O2c_Error with "a VAR ARRAY OF parameter needs a "
                 & "writable array, not a value ARRAY OF parameter (line "
                 & Natural'Image (Cur.Line) & ")";
            end if;
            A.Text := To_Unbounded_String (Cur.Text (1 .. Cur.Len));
            Next;
            return A;
         end;
      end if;
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
         if Formal.Typ = T_Long and then A.Typ = T_Int and then A.Lit then
            null;                     --  literal widens to LONGINT (M17)
         elsif Formal.Typ = T_Real and then A.Typ = T_Int then
            A.Text := To_Unbounded_String ("Float (" & To_String (A.Text)
                                           & ")");   --  int widens (M18)
         elsif A.Typ /= Formal.Typ then
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
         elsif A.Typ /= T_Ptr then
            raise O2c_Error with "argument must be a pointer of type "
              & To_String (UTypes (Formal.UT).Name) & " or NIL (line "
              & Natural'Image (Cur.Line) & ")";
         elsif A.Ptr_UT /= Formal.UT then
            --  widening for VALUE pointer formals only (M13)
            if Formal.By_Ref
              or else not UTypes (A.Ptr_UT).Is_Ptr
              or else not UTypes (Formal.UT).Is_Ptr
              or else not Rec_Descends (UTypes (A.Ptr_UT).Ptr_Tgt,
                                        UTypes (Formal.UT).Ptr_Tgt)
            then
               raise O2c_Error with "argument must be a pointer of type "
                 & To_String (UTypes (Formal.UT).Name) & " or NIL (line "
                 & Natural'Image (Cur.Line) & ")";
            end if;
            A.Text := To_Unbounded_String
              (To_String (UTypes (Formal.UT).Name) & " (" & To_String (A.Text)
               & ")");
         end if;
      end if;
      return A;
   end Parse_Actual;

   --  Emit a type-bound procedure call.  Cur is just past the method
   --  name; Recv is the Ada receiver expression (a record variable or
   --  p.all).  Formal #1 is the receiver, so the actual count must be
   --  Params - 1.  When Td /= 0 (pointer receiver whose static target
   --  is record Td) and Td's subtree overrides the method, a dynamic
   --  tag chain is emitted (M14): the runtime object's most-derived
   --  overriding implementation wins, else the static binding.
   procedure Emit_Method_Call (BI : Natural; Recv : String;
                               Td : Natural := 0) is
      SIdx : constant Natural := Bounds (BI).SymIdx;
      NPar : constant Natural := Syms (SIdx).Params;
      Exp  : constant Natural := NPar - 1;
      MName : constant String := To_String (Bounds (BI).Name);
      Args  : array (1 .. Max_Params - 1) of Unbounded_String;
      N_A   : Natural := 0;
      Cand  : array (1 .. Max_Bound) of Natural := (others => 0);
      N_C   : Natural := 0;
      BaseB : constant Natural := Bounds (BI).RecUT;
      ArgT  : Unbounded_String;
   begin
      --  parse the actual arguments once; their texts are reused by
      --  every branch of a dispatch chain
      if Cur.Kind = Lex.Tok_LParen then
         Next;
         loop
            exit when Cur.Kind = Lex.Tok_RParen;
            N_A := N_A + 1;
            if N_A > Exp then
               raise O2c_Error with "method '" & MName & "' expects "
                 & Natural'Image (Exp) & " argument(s)";
            end if;
            declare
               A : Expr_Rec := Parse_Actual (Syms (SIdx).P (N_A + 1));
            begin
               Args (N_A) := A.Text;
            end;
            exit when Cur.Kind /= Lex.Tok_Comma;
            Next;
         end loop;
         if N_A /= Exp then
            raise O2c_Error with "method '" & MName & "' expects "
              & Natural'Image (Exp) & " argument(s), got "
              & Natural'Image (N_A);
         end if;
         Expect (Lex.Tok_RParen, "')'");
         Next;
      else
         if Exp /= 0 then
            raise O2c_Error with "method '" & MName & "' expects "
              & Natural'Image (Exp) & " argument(s)";
         end if;
      end if;
      for I in 1 .. N_A loop
         if I > 1 then
            ArgT := ArgT & ", ";
         end if;
         ArgT := ArgT & Args (I);
      end loop;

      --  record types in Td's subtree that override M (deepest first)
      if Td /= 0 then
         for X in 1 .. N_UT loop
            if UTypes (X).Is_Rec and then Rec_Descends (X, Td) then
               for B in 1 .. N_Bound loop
                  if Bounds (B).RecUT = X
                    and then To_String (Bounds (B).Name) = MName
                  then
                     declare
                        Pos : Positive := N_C + 1;
                     begin
                        while Pos > 1 and then
                          Rec_Depth (X) > Rec_Depth (Cand (Pos - 1))
                        loop
                           Cand (Pos) := Cand (Pos - 1);
                           Pos := Pos - 1;
                        end loop;
                        Cand (Pos) := X;
                     end;
                     N_C := N_C + 1;
                  end if;
               end loop;
            end if;
         end loop;
      end if;

      if Td /= 0 and then N_C > 0 then
         --  dynamic dispatch: tag chain, deepest override first
         for I in 1 .. N_C loop
            Append_Body ("      " & (if I = 1 then "if " else "elsif ")
                         & Recv & " in " & To_String (UTypes (Cand (I)).Name)
                         & "'Class then");
            Append_Body ("         "
                         & Method_Impl_Name (MName, Cand (I)) & " ("
                         & To_String (UTypes (Cand (I)).Name) & " (" & Recv
                         & ")"
                         & (if N_A > 0 then ", " & To_String (ArgT) else "")
                         & ");");
         end loop;
         Append_Body ("      else");
         Append_Body ("         "
                      & Method_Impl_Name (MName, BaseB) & " ("
                      & To_String (UTypes (BaseB).Name) & " (" & Recv & ")"
                      & (if N_A > 0 then ", " & To_String (ArgT) else "")
                      & ");");
         Append_Body ("      end if;");
      else
         --  static binding
         declare
            RecvA : String := Recv;
         begin
            if Td /= 0 then
               RecvA := To_String (UTypes (BaseB).Name) & " (" & Recv & ")";
            end if;
            Append_Body ("      " & Method_Impl_Name (MName, BaseB)
                         & " (" & RecvA
                         & (if N_A > 0 then ", " & To_String (ArgT) else "")
                         & ");");
         end;
      end if;
   end Emit_Method_Call;

   --  Assign a POINTER value (designator or NIL) to an Ada LHS whose
   --  pointer user type is LHS_UT; type-check the value first (M8).
   procedure Assign_Pointer (LHS : String; LHS_UT : Natural) is
      R    : Expr_Rec := Parse_Expr;
      Conv : Boolean := False;
   begin
      if R.Typ = T_Nil then
         null;
      elsif R.Typ = T_Ptr then
         if R.Ptr_UT /= LHS_UT then
            --  widening: assign a pointer to an extension into a
            --  pointer to its ancestor (M13)
            if not UTypes (LHS_UT).Is_Ptr or else not UTypes (R.Ptr_UT).Is_Ptr
              or else not Rec_Descends (UTypes (R.Ptr_UT).Ptr_Tgt,
                                        UTypes (LHS_UT).Ptr_Tgt)
            then
               raise O2c_Error with "pointer type mismatch assigning " & LHS;
            end if;
            Conv := True;
         end if;
      else
         raise O2c_Error with "pointer type mismatch assigning " & LHS;
      end if;
      if Conv then
         Append_Body ("      " & LHS & " := "
                      & To_String (UTypes (LHS_UT).Name) & " ("
                      & To_String (R.Text) & ");");
      else
         Append_Body ("      " & LHS & " := " & To_String (R.Text) & ";");
      end if;
   end Assign_Pointer;

   function Parse_Factor return Expr_Rec is
      R  : Expr_Rec;
      Id : Natural;
   begin
      case Cur.Kind is
         when Lex.Tok_Number =>
            R.Text := To_Unbounded_String (Cur.Text (1 .. Cur.Len));
            R.Typ := T_Int;
            for I in 1 .. Cur.Len loop
               if Cur.Text (I) = '.' then
                  R.Typ := T_Real;      --  REAL literal (M18)
               end if;
            end loop;
            R.Lit := True;
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
         when Lex.Tok_LBrace =>
            --  SET literal: { e1, e2, ... } (M17), elements 0..31
            Used_Set := True;
            Next;              --  past '{'
            R.Typ := T_Set;
            declare
               Bit   : Unbounded_String;
               First : Boolean := True;
            begin
               loop
                  exit when Cur.Kind = Lex.Tok_RBrace;
                  declare
                     E : Expr_Rec := Parse_Expr;
                  begin
                     if E.Typ /= T_Int then
                        raise O2c_Error with "set elements must be INTEGER "
                          & "(line " & Natural'Image (Cur.Line) & ")";
                     end if;
                     if First then
                        First := False;
                     else
                        Bit := Bit & " or ";
                     end if;
                     Bit := Bit
                       & "O2c_Set (Interfaces.Shift_Left "
                       & "(Interfaces.Unsigned_32 (1), "
                       & To_String (E.Text) & "))";
                  end;
                  exit when Cur.Kind /= Lex.Tok_Comma;
                  Next;
               end loop;
               Expect (Lex.Tok_RBrace, "'}' closing a SET literal");
               Next;
               if First then
                  R.Text := To_Unbounded_String ("O2c_Set (0)");
               else
                  R.Text := "(" & Bit & ")";
               end if;
            end;
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
               if R.Typ /= T_Int and then R.Typ /= T_Long
                 and then R.Typ /= T_Real
               then
                  raise O2c_Error with "unary sign needs an INTEGER, "
                    & "LONGINT or REAL (line "
                    & Natural'Image (Cur.Line) & ")";
               end if;
               R.Text := (if Neg then "-" else "") & "(" & R.Text & ")";
            end;
         when Lex.Tok_Ident =>
            if Eq_No_Case (Cur.Text (1 .. Cur.Len), "LEN") then
               --  LEN(array): predeclared length (M12)
               Next;             --  past LEN
               Expect (Lex.Tok_LParen, "'(' after LEN");
               Next;
               if Cur.Kind /= Lex.Tok_Ident then
                  raise O2c_Error with "LEN needs an array variable "
                    & "(line " & Natural'Image (Cur.Line) & ")";
               end if;
               declare
                  LId : constant Natural := Find (Cur.Text (1 .. Cur.Len));
                  LNm : constant String := Cur.Text (1 .. Cur.Len);
               begin
                  if LId = 0 or else Syms (LId).Kind /= S_Var
                    or else not ((Syms (LId).UT /= 0
                                  and then not UTypes (Syms (LId).UT).Is_Rec
                                  and then not UTypes (Syms (LId).UT).Is_Ptr)
                                 or else Syms (LId).Open_Arr)
                  then
                     raise O2c_Error with "LEN needs an ARRAY variable "
                       & "('" & LNm & "' is not one) (line "
                       & Natural'Image (Cur.Line) & ")";
                  end if;
                  R.Text := To_Unbounded_String (LNm) & "'Length";
                  R.Typ := T_Int;
                  Next;
                  Expect (Lex.Tok_RParen, "')' after the LEN argument");
                  Next;
               end;
               return R;
            end if;
            --  imported module member (M19): Math.const / Math.var reads
            --  and Math.func(...) calls keep their qualification in the
            --  generated Ada (the library module is an Ada package).
            declare
               FNm : constant String := Cur.Text (1 .. Cur.Len);
            begin
               if Imported_Mod (FNm) then
                  declare
                     T1 : Lex.Token := Lex.Peek_Token;
                  begin
                     if T1.Kind = Lex.Tok_Dot then
                        Next;       --  past the module name
                        Next;       --  past '.'
                        Expect (Lex.Tok_Ident, "a member name");
                        declare
                           MName : constant String := Cur.Text (1 .. Cur.Len);
                           XI    : Natural;
                        begin
                           Next;
                           XI := Find_X (FNm, MName);
                           if XI = 0 then
                              raise O2c_Error with "'" & FNm & "." & MName
                                & "' is not exported by module " & FNm;
                           end if;
                           if Xs (XI).Kind = S_Const or else
                              Xs (XI).Kind = S_Var
                           then
                              R.Text := To_Unbounded_String
                                (FNm & "." & MName);
                              R.Typ := Xs (XI).Typ;
                              R.Lit := False;
                              return R;
                           end if;
                           if not Xs (XI).Ret then
                              raise O2c_Error with "'" & FNm & "." & MName
                                & "' is a proper procedure, not a function";
                           end if;
                           --  result: scalar, or an exported POINTER type
                           --  of the module (M20b)
                           if Length (Xs (XI).Ret_Nm) > 0 then
                              R.Typ := T_Ptr;
                              R.Ptr_UT := X_Ret_UT (XI);
                           else
                              R.Typ := Xs (XI).Typ;
                           end if;
                           if Cur.Kind = Lex.Tok_LParen then
                              Next;
                              declare
                                 Args : array (1 .. Max_Params)
                                   of Unbounded_String;
                                 N_A  : Natural := 0;
                                 Call : Unbounded_String;
                              begin
                                 loop
                                    exit when Cur.Kind = Lex.Tok_RParen;
                                    N_A := N_A + 1;
                                    if N_A > Max_Params then
                                       raise O2c_Error with "too many "
                                         & "arguments";
                                    end if;
                                    declare
                                       A : Expr_Rec :=
                                         Parse_Actual (X_Formal (XI, N_A));
                                    begin
                                       Args (N_A) := A.Text;
                                    end;
                                    exit when Cur.Kind /= Lex.Tok_Comma;
                                    Next;
                                 end loop;
                                 if N_A /= Xs (XI).Params then
                                    raise O2c_Error with "call expects "
                                      & Natural'Image (Xs (XI).Params)
                                      & " argument(s), got "
                                      & Natural'Image (N_A);
                                 end if;
                                 Expect (Lex.Tok_RParen, "')'");
                                 Next;
                                 Call := Call & FNm & "." & MName & " (";
                                 for I in 1 .. N_A loop
                                    if I > 1 then
                                       Call := Call & ", ";
                                    end if;
                                    Call := Call & Args (I);
                                 end loop;
                                 Call := Call & ")";
                                 R.Text := Call;
                              end;
                           elsif Xs (XI).Params /= 0 then
                              raise O2c_Error with "'" & FNm & "." & MName
                                & "' needs arguments";
                           else
                              R.Text := To_Unbounded_String
                                (FNm & "." & MName);
                           end if;
                           return R;
                        end;
                     end if;
                  end;
               end if;
            end;
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
                  if UTypes (U).Is_Ptr and then Cur.Kind = Lex.Tok_Is then
                     --  p IS T: class-wide membership test (M13)
                     Next;
                     Expect (Lex.Tok_Ident, "a record type after IS");
                     declare
                        TT  : constant Natural := Find_UT (Cur.Text (1 .. Cur.Len));
                        Trc : constant Natural := UTypes (U).Ptr_Tgt;
                     begin
                        if TT = 0 or else not UTypes (TT).Is_Rec
                          or else not (Rec_Descends (TT, Trc)
                                       or else Rec_Descends (Trc, TT))
                        then
                           raise O2c_Error with "'" & Cur.Text (1 .. Cur.Len)
                             & "' is not in the record hierarchy of this "
                             & "POINTER type (line "
                             & Natural'Image (Cur.Line) & ")";
                        end if;
                        R.Text := To_Unbounded_String
                          ("(" & Nm & ".all in "
                           & To_String (UTypes (TT).Name) & "'Class)");
                        R.Typ := T_Bool;
                        Next;
                     end;
                     return R;
                  end if;
                  if Cur.Kind = Lex.Tok_Dot then
                     --  method function call r.M(...) / p.M(...) (M15):
                     --  detect via lookahead (member then '(')
                     declare
                        T1 : Lex.Token;
                        T2 : Lex.Token;
                        Mb : String (1 .. 64);
                        M_Len : Natural := 0;
                     begin
                        Lex.Peek_Token2 (T1, T2);
                        if T1.Kind = Lex.Tok_Ident and then
                          T2.Kind = Lex.Tok_LParen
                        then
                           M_Len := T1.Len;
                           Mb (1 .. M_Len) := T1.Text (1 .. T1.Len);
                           declare
                              Urec : constant Natural :=
                                (if UTypes (U).Is_Ptr
                                 then UTypes (U).Ptr_Tgt
                                 else U);
                              BI : constant Natural :=
                                Bound_Find (Urec, Mb (1 .. M_Len));
                           begin
                              if BI /= 0
                                and then Syms (Bounds (BI).SymIdx).Ret
                              then
                                 declare
                                    SIdx : constant Natural :=
                                      Bounds (BI).SymIdx;
                                    DN : constant String :=
                                      To_String (Bounds (BI).Name);
                                    BB : constant Natural :=
                                      Bounds (BI).RecUT;
                                    Rcv : constant String :=
                                      (if UTypes (U).Is_Ptr
                                       then Nm & ".all"
                                       else Nm);
                                    Exp : constant Natural :=
                                      Syms (SIdx).Params - 1;
                                    Call : Unbounded_String;
                                    N_A  : Natural := 0;
                                 begin
                                    Next;   --  past '.'
                                    Expect (Lex.Tok_Ident, "a method name");
                                    Next;   --  past method name
                                    Expect (Lex.Tok_LParen, "'('");
                                    Next;
                                    Call := Call
                                      & Dsp_Name (DN, BB) & " (" & Rcv;
                                    loop
                                       exit when
                                         Cur.Kind = Lex.Tok_RParen;
                                       N_A := N_A + 1;
                                       if N_A > Exp then
                                          raise O2c_Error with "method '"
                                            & DN & "' expects "
                                            & Natural'Image (Exp)
                                            & " argument(s)";
                                       end if;
                                       declare
                                          A : Expr_Rec := Parse_Actual
                                            (Syms (SIdx).P (N_A + 1));
                                       begin
                                          Call := Call & ", "
                                            & To_String (A.Text);
                                       end;
                                       exit when
                                         Cur.Kind /= Lex.Tok_Comma;
                                       Next;
                                    end loop;
                                    if N_A /= Exp then
                                       raise O2c_Error with "method '"
                                         & DN & "' expects "
                                         & Natural'Image (Exp)
                                         & " argument(s), got "
                                         & Natural'Image (N_A);
                                    end if;
                                    Expect (Lex.Tok_RParen, "')'");
                                    Next;
                                    Call := Call & ")";
                                    R.Text := Call;
                                    if Syms (SIdx).UT /= 0 then
                                       R.Typ := T_Ptr;
                                       R.Ptr_UT := Syms (SIdx).UT;
                                    else
                                       R.Typ := Syms (SIdx).Typ;
                                    end if;
                                    return R;
                                 end;
                              end if;
                           end;
                        end if;
                     end;
                  end if;
                  --  user-type designator chain (M16): '.field' / '^'
                  --  deref / '[index]' selectors over record, pointer
                  --  and array values, ending on a scalar, pointer or
                  --  whole ARRAY OF CHAR.
                  declare
                     D : Desig := Parse_Rec_Ptr_Chain (Nm, U);
                  begin
                     if D.K = D_Scalar then
                        R.Typ := D.Sc;
                     elsif D.K = D_Ptr then
                        R.Typ := T_Ptr;
                        R.Ptr_UT := D.UT;
                     else
                        R.Typ := T_Str;
                        R.CStr := True;
                     end if;
                     R.Text := D.Text;
                  end;
                  return R;
               end;
            elsif Syms (Id).Kind = S_Var and then Syms (Id).Open_Arr then
               --  ARRAY OF parameter: index (or the whole CHAR value),
               --  like a fixed array of the parameter's element type.
               declare
                  Nm : constant String := Cur.Text (1 .. Cur.Len);
               begin
                  Next;              --  past the parameter name
                  if Syms (Id).Typ = T_Char then
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
                     R.Typ := Syms (Id).Typ;
                  end;
                  Expect (Lex.Tok_RBracket, "']'");
                  Next;
                  return R;
               end;
            else
               R.Text := To_Unbounded_String (Cur.Text (1 .. Cur.Len));
               R.Typ := Syms (Id).Typ;
               Next;
            end if;
         when others =>
            raise O2c_Error with "expression expected at line "
              & Natural'Image (Cur.Line);
      end case;
      return R;
   end Parse_Factor;

   --  INTEGER/LONGINT compatibility (M17): mixing is allowed only when
   --  one side is a plain numeric literal, which widens to LONGINT.
   function Int_Like (A, B : Expr_Rec; Res : out EType) return Boolean is
   begin
      if A.Typ = T_Int and then B.Typ = T_Int then
         Res := T_Int;
         return True;
      elsif A.Typ = T_Long and then B.Typ = T_Long then
         Res := T_Long;
         return True;
      elsif A.Typ = T_Long and then B.Typ = T_Int and then B.Lit then
         Res := T_Long;
         return True;
      elsif A.Typ = T_Int and then A.Lit and then B.Typ = T_Long then
         Res := T_Long;
         return True;
      end if;
      Res := T_Int;
      return False;
   end Int_Like;

   --  REAL compatibility (M18): mixing REAL with INTEGER is allowed
   --  only when the INTEGER side is a plain numeric literal.
   function Real_Like (A, B : Expr_Rec; Res : out EType) return Boolean is
   begin
      if A.Typ = T_Real and then B.Typ = T_Real then
         Res := T_Real;
         return True;
      elsif A.Typ = T_Real and then B.Typ = T_Int and then B.Lit then
         Res := T_Real;
         return True;
      elsif A.Typ = T_Int and then A.Lit and then B.Typ = T_Real then
         Res := T_Real;
         return True;
      end if;
      Res := T_Real;
      return False;
   end Real_Like;

   function Parse_Term return Expr_Rec is
      R : Expr_Rec := Parse_Factor;
   begin
      loop
         if Cur.Kind = Lex.Tok_Star then
            Next;
            declare
               X : Expr_Rec := Parse_Factor;
               Res : EType;
            begin
               if R.Typ = T_Set and then X.Typ = T_Set then
                  R.Text := "(" & R.Text & " and " & X.Text & ")";
                  R.Lit := False;
               elsif Int_Like (R, X, Res) then
                  R.Text := R.Text & " * " & X.Text;
                  R.Typ := Res;
                  R.Lit := False;
               elsif Real_Like (R, X, Res) then
                  if R.Typ = T_Int then
                     R.Text := To_Unbounded_String
                       ("Float (" & To_String (R.Text) & ")");
                  elsif X.Typ = T_Int then
                     X.Text := To_Unbounded_String
                       ("Float (" & To_String (X.Text) & ")");
                  end if;
                  R.Text := R.Text & " * " & X.Text;
                  R.Typ := Res;
                  R.Lit := False;
               else
                  raise O2c_Error with "'*' needs INTEGER/LONGINT, REAL or "
                    & "SET operands";
               end if;
            end;
         elsif Cur.Kind = Lex.Tok_Div then
            --  integer DIV (keyword); '/' does REAL division
            Next;
            declare
               X : Expr_Rec := Parse_Factor;
               Res : EType;
            begin
               if not Int_Like (R, X, Res) then
                  raise O2c_Error with "DIV needs INTEGER/LONGINT operands";
               end if;
               R.Text := R.Text & " / " & X.Text;
               R.Typ := Res;
               R.Lit := False;
            end;
         elsif Cur.Kind = Lex.Tok_Mod then
            Next;
            declare
               X : Expr_Rec := Parse_Factor;
               Res : EType;
            begin
               if not Int_Like (R, X, Res) then
                  raise O2c_Error with "MOD needs INTEGER/LONGINT operands";
               end if;
               R.Text := R.Text & " rem " & X.Text;
               R.Typ := Res;
               R.Lit := False;
            end;
         elsif Cur.Kind = Lex.Tok_Slash then
            --  '/' is REAL division, or SET symmetric difference
            Next;
            declare
               X : Expr_Rec := Parse_Factor;
               Res : EType;
            begin
               if R.Typ = T_Set and then X.Typ = T_Set then
                  R.Text := "(" & R.Text & " xor " & X.Text & ")";
                  R.Lit := False;
               elsif Real_Like (R, X, Res) then
                  if R.Typ = T_Int then
                     R.Text := To_Unbounded_String
                       ("Float (" & To_String (R.Text) & ")");
                  elsif X.Typ = T_Int then
                     X.Text := To_Unbounded_String
                       ("Float (" & To_String (X.Text) & ")");
                  end if;
                  R.Text := R.Text & " / " & X.Text;
                  R.Typ := Res;
                  R.Lit := False;
               else
                  raise O2c_Error with "'/' needs REAL (or SET) operands";
               end if;
            end;
         elsif Cur.Kind = Lex.Tok_Amp then
            Next;
            declare
               X : Expr_Rec := Parse_Factor;
            begin
               if R.Typ /= T_Bool or else X.Typ /= T_Bool then
                  raise O2c_Error with "'&' needs BOOLEAN operands";
               end if;
               R.Text := R.Text & " and " & X.Text;
               R.Lit := False;
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
               Res : EType;
            begin
               if R.Typ = T_Set and then X.Typ = T_Set then
                  R.Text := "(" & R.Text & " or " & X.Text & ")";
                  R.Lit := False;
               elsif Int_Like (R, X, Res) then
                  R.Text := R.Text & " + " & X.Text;
                  R.Typ := Res;
                  R.Lit := False;
               elsif Real_Like (R, X, Res) then
                  if R.Typ = T_Int then
                     R.Text := To_Unbounded_String
                       ("Float (" & To_String (R.Text) & ")");
                  elsif X.Typ = T_Int then
                     X.Text := To_Unbounded_String
                       ("Float (" & To_String (X.Text) & ")");
                  end if;
                  R.Text := R.Text & " + " & X.Text;
                  R.Typ := Res;
                  R.Lit := False;
               else
                  raise O2c_Error with "'+' needs INTEGER/LONGINT, REAL or "
                    & "SET operands";
               end if;
            end;
         elsif Cur.Kind = Lex.Tok_Minus then
            Next;
            declare
               X : Expr_Rec := Parse_Term;
               Res : EType;
            begin
               if R.Typ = T_Set and then X.Typ = T_Set then
                  R.Text := "(" & R.Text & " and not " & X.Text & ")";
                  R.Lit := False;
               elsif Int_Like (R, X, Res) then
                  R.Text := R.Text & " - " & X.Text;
                  R.Typ := Res;
                  R.Lit := False;
               elsif Real_Like (R, X, Res) then
                  if R.Typ = T_Int then
                     R.Text := To_Unbounded_String
                       ("Float (" & To_String (R.Text) & ")");
                  elsif X.Typ = T_Int then
                     X.Text := To_Unbounded_String
                       ("Float (" & To_String (X.Text) & ")");
                  end if;
                  R.Text := R.Text & " - " & X.Text;
                  R.Typ := Res;
                  R.Lit := False;
               else
                  raise O2c_Error with "'-' needs INTEGER/LONGINT, REAL or "
                    & "SET operands";
               end if;
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
               R.Lit := False;
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
      if Cur.Kind = Lex.Tok_In then
         --  membership test: e IN s (M17)
         Next;
         declare
            X : Expr_Rec := Parse_Simple;
         begin
            if R.Typ /= T_Int or else X.Typ /= T_Set then
               raise O2c_Error with "IN needs an INTEGER element and a SET "
                 & "operand (line " & Natural'Image (Cur.Line) & ")";
            end if;
            Used_Set := True;
            R.Text := To_Unbounded_String
              ("((" & To_String (X.Text)
               & " and O2c_Set (Interfaces.Shift_Left "
               & "(Interfaces.Unsigned_32 (1), " & To_String (R.Text)
               & "))) /= 0)");
            R.Typ := T_Bool;
            R.Lit := False;
            return R;
         end;
      end if;
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
            Is_LE : constant Boolean := Cur.Kind = Lex.Tok_LE;
            Is_GE : constant Boolean := Cur.Kind = Lex.Tok_GE;
         begin
            Next;
            declare
               X  : Expr_Rec := Parse_Simple;
               Res : EType;
            begin
               if Ordering then
                  if R.Typ = T_Set and then X.Typ = T_Set then
                     --  SET subset relations (only <= and >=)
                     if not (Is_LE or Is_GE) then
                        raise O2c_Error with "SET ordering supports only "
                          & "'<=' and '>=' (line "
                          & Natural'Image (Cur.Line) & ")";
                     end if;
                     Used_Set := True;
                     if Is_LE then
                        R.Text := To_Unbounded_String
                          ("((" & To_String (R.Text) & " and not "
                           & To_String (X.Text) & ") = 0)");
                     else
                        R.Text := To_Unbounded_String
                          ("((" & To_String (X.Text) & " and not "
                           & To_String (R.Text) & ") = 0)");
                     end if;
                     R.Typ := T_Bool;
                     R.Lit := False;
                     return R;
                  elsif not Int_Like (R, X, Res)
                    and then not Real_Like (R, X, Res)
                  then
                     raise O2c_Error with "ordering comparisons need "
                       & "INTEGER/LONGINT, REAL or SET operands";
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
                     --  scalar equality: INTEGER/LONGINT (literal
                     --  widening), BOOLEAN, CHAR, SET
                     if not (R.Typ = T_Set and then X.Typ = T_Set)
                       and then not Int_Like (R, X, Res)
                       and then not Real_Like (R, X, Res)
                     then
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
                             or else (R.Typ /= T_Int and then R.Typ /= T_Long
                                      and then R.Typ /= T_Bool
                                      and then R.Typ /= T_Char
                                      and then R.Typ /= T_Set)
                           then
                              raise O2c_Error with "'='/'#' operands must "
                                & "match (INTEGER, LONGINT, BOOLEAN, CHAR "
                                & "or SET)";
                           end if;
                        end;
                     end if;
                  end if;
               end if;
               if R.Typ = T_Real and then X.Typ = T_Int then
                  X.Text := To_Unbounded_String
                    ("Float (" & To_String (X.Text) & ")");
               elsif R.Typ = T_Int and then X.Typ = T_Real then
                  R.Text := To_Unbounded_String
                    ("Float (" & To_String (R.Text) & ")");
               end if;
               R.Text := "(" & R.Text & Op & X.Text & ")";
               R.Typ := T_Bool;
               R.Lit := False;
            end;
         end;
      end if;
      return R;
   end Parse_Expr;

   --  declarations ------------------------------------------------

   procedure Decl_Const is
      Name : constant String := Ident_Text;
      V    : Expr_Rec;
      Exp  : Boolean := False;
   begin
      Next;                       --  past the name
      if Cur.Kind = Lex.Tok_Star then
         Exp := True;             --  export mark (M19)
         Next;
      end if;
      if Exp and then In_Proc then
         raise O2c_Error with "constants cannot be exported inside a "
           & "procedure";
      end if;
      Expect (Lex.Tok_Equal, "'='");
      Next;
      V := Parse_Expr;
      Expect (Lex.Tok_Semi, "';'");
      Next;

      N_Sym := N_Sym + 1;
      Syms (N_Sym) := (Kind => S_Const, Typ => V.Typ,
                       Name => To_Unbounded_String (Name), Exp => Exp,
                       others => <>);
      if Exp and then Pkg_Mode then
         if not V.Lit and then V.Typ /= T_Str then
            raise O2c_Error with "exported constants must be plain "
              & "literals (M19; '" & Name & "')";
         end if;
         if V.Typ /= T_Str and then not Scalar_Exportable (V.Typ) then
            raise O2c_Error with "exported constants: INTEGER/LONGINT/"
              & "REAL/CHAR/BOOLEAN/string only ('" & Name & "')";
         end if;
         Append_Spec ("   " & Name & " : constant " & Ada_Type (V.Typ)
                      & " := " & To_String (V.Text) & ";");
         X_Add (To_String (Mod_Name),
                (Kind => S_Const, Typ => V.Typ,
                 Name => To_Unbounded_String (Name), others => <>));
      else
         Append_Decl ("   " & Name & " : constant " & Ada_Type (V.Typ)
                      & " := " & To_String (V.Text) & ";");
      end if;
   end Decl_Const;

   procedure Decl_Var is
      Names : array (1 .. 16) of Unbounded_String;
      Exps  : array (1 .. 16) of Boolean := (others => False);
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
         if Cur.Kind = Lex.Tok_Star then
            Exps (N) := True;      --  export mark (M19)
            Next;
         end if;
         exit when Cur.Kind /= Lex.Tok_Comma;
         Next;
      end loop;

      for I in 1 .. N loop
         if Exps (I) and then In_Proc then
            raise O2c_Error with "variables cannot be exported inside a "
              & "procedure";
         end if;
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
               if Imported_Mod (T)
                 and then Lex.Peek_Token.Kind = Lex.Tok_Dot
               then
                  --  variable of an imported exported type (M20)
                  Next;              --  past the module name
                  Next;              --  past '.'
                  Expect (Lex.Tok_Ident, "an exported type name");
                  UT := Import_Type (T, Cur.Text (1 .. Cur.Len));
                  Is_UT := True;
                  Next;
               else
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
               end if;
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
            else
               Init_Txt := Init_Txt & Value_Init (UT);
            end if;
            for I in 1 .. N loop
               if Exps (I) then
                  raise O2c_Error with "only scalar VARIABLEs can be "
                    & "exported (M19; '" & To_String (Names (I)) & "')";
               end if;
               N_Sym := N_Sym + 1;
               Syms (N_Sym) := (Kind => S_Var, Typ => T_Int, UT => UT,
                                Name => Names (I), others => <>);
               Append_Decl ("   " & To_String (Names (I)) & " : "
                            & To_String (UTypes (UT).Name) & " := "
                            & To_String (Init_Txt) & ";");
            end loop;
         else
            for I in 1 .. N loop
               if Exps (I) and then
                 not (Scalar_Exportable (Typ) and then Typ /= T_Set)
               then
                  raise O2c_Error with "exported VARIABLEs: INTEGER/"
                    & "LONGINT/REAL/CHAR/BOOLEAN only (M19; '"
                    & To_String (Names (I)) & "')";
               end if;
               N_Sym := N_Sym + 1;
               Syms (N_Sym) := (Kind => S_Var, Typ => Typ,
                                Name => Names (I), Exp => Exps (I),
                                others => <>);
               if Exps (I) and then Pkg_Mode then
                  Append_Spec ("   " & To_String (Names (I)) & " : "
                               & Ada_Type (Typ) & " := "
                               & Scalar_Init (Typ) & ";");
                  X_Add (To_String (Mod_Name),
                         (Kind => S_Var, Typ => Typ,
                          Name => Names (I), others => <>));
               else
                  Append_Decl ("   " & To_String (Names (I)) & " : "
                               & Ada_Type (Typ) & " := " & Scalar_Init (Typ)
                               & ";");
               end if;
            end loop;
         end if;
      end;
   end Decl_Var;

   procedure Decl_Type is
      Name : constant String := Ident_Text;
      UTI  : Natural;
      Exp  : Boolean := False;
   begin
      if Find_UT (Name) /= 0 then
         raise O2c_Error with "type '" & Name & "' is already declared "
           & "(line " & Natural'Image (Cur.Line) & ")";
      end if;
      Next;                       --  past the type name
      if Cur.Kind = Lex.Tok_Star then
         Exp := True;             --  export mark (M20)
         Next;
      end if;
      if Exp and then In_Proc then
         raise O2c_Error with "types cannot be exported inside a "
           & "procedure";
      end if;
      Expect (Lex.Tok_Equal, "'='");
      Next;

      N_UT := N_UT + 1;
      if N_UT > UTypes'Last then
         raise O2c_Error with "too many type declarations";
      end if;
      UTI := N_UT;
      UTypes (UTI) := (Name => To_Unbounded_String (Name),
                       Is_Rec => True, ExpT => (Pkg_Mode and then Exp),
                       others => <>);
      Spec_Decl := UTypes (UTI).ExpT;

      if Cur.Kind = Lex.Tok_Array then
         if UTypes (UTI).ExpT then
            raise O2c_Error with "exported fixed ARRAY types are M20b "
              & "(found '" & Name & "')";
         end if;
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
            --  element is a user type: an earlier ARRAY or RECORD (M16)
            declare
               EU : constant Natural := Find_UT (Cur.Text (1 .. Cur.Len));
            begin
               if EU = 0 or else UTypes (EU).Is_Ptr then
                  raise O2c_Error with "array element types: INTEGER/BOOLEAN/"
                    & "CHAR or an earlier ARRAY/RECORD type ('"
                    & Cur.Text (1 .. Cur.Len) & "')";
               end if;
               UTypes (UTI).Elem_UT := EU;
            end;
         end if;
         Next;
         UTypes (UTI).Is_Rec := False;
         if UTypes (UTI).Elem_UT /= 0 then
            Append_Decl ("   type " & Name & " is array (0 .. "
                         & Integer'Image (UTypes (UTI).Arr_Len - 1)
                         & ") of "
                         & To_String (UTypes (UTypes (UTI).Elem_UT).Name)
                         & ";");
         elsif UTypes (UTI).Elem = T_Char then
            Append_Decl ("   subtype " & Name & " is String (1 .. "
                         & Integer'Image (UTypes (UTI).Arr_Len) & ");");
         else
            --  numeric fixed arrays are constrained subtypes of the
            --  shared open-array base so they also fit ARRAY OF formals
            if UTypes (UTI).Elem = T_Int then
               Used_Int_Arr := True;
            else
               Used_Bool_Arr := True;
            end if;
            Append_Decl ("   subtype " & Name & " is "
                         & (if UTypes (UTI).Elem = T_Int
                           then "O2c_Int_Arr"
                           else "O2c_Bool_Arr")
                         & " (0 .. "
                         & Integer'Image (UTypes (UTI).Arr_Len - 1) & ");");
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
               Append_Decl ("   type " & Name & " is access all " & TName
                         & "'Class;");
            end if;
         end;
      elsif Cur.Kind = Lex.Tok_Record then
         Next;
         --  optional extension clause: RECORD (Parent) ... (M13)
         if Cur.Kind = Lex.Tok_LParen then
            Next;
            Expect (Lex.Tok_Ident, "the parent record type after '('");
            declare
               PT : constant Natural := Find_UT (Cur.Text (1 .. Cur.Len));
            begin
               if PT = 0 then
                  raise O2c_Error with "unknown parent record type '"
                    & Cur.Text (1 .. Cur.Len) & "' (line "
                    & Natural'Image (Cur.Line) & ")";
               end if;
               if not UTypes (PT).Is_Rec or else UTypes (PT).Is_Ext
                 or else UTypes (PT).Is_Ptr
               then
                  raise O2c_Error with "'" & Cur.Text (1 .. Cur.Len)
                    & "' is not an extensible RECORD type (line "
                    & Natural'Image (Cur.Line) & ")";
               end if;
               UTypes (UTI).Is_Ext := True;
               UTypes (UTI).Parent := PT;
            end;
            Next;
            Expect (Lex.Tok_RParen, "')' after the parent record type");
            Next;
         end if;
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
                          & "CHAR or an earlier user type ('" & TN & "')";
                     end if;
                     FT := T_Int;      --  scalar slot unused for user types
                  end if;
               end;
               Next;
               if Cur.Kind = Lex.Tok_Semi then
                  Next;             --  optional separator before END
               end if;
               for I in 1 .. NF loop
                  if UTypes (UTI).Parent /= 0 then
                     declare
                        Own : Natural;
                     begin
                        if Field_Of (UTypes (UTI).Parent,
                                     To_String (FNames (I)), Own) /= 0 then
                           raise O2c_Error with "field '"
                             & To_String (FNames (I))
                             & "' redefines a field of the parent record "
                             & To_String
                               (UTypes (UTypes (UTI).Parent).Name);
                        end if;
                     end;
                  end if;
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
                               & " is access all " & Name & "'Class;");
               end if;
            end loop;
         end;
         Append_Decl ("   type " & Name
                      & (if UTypes (UTI).Is_Ext then
                           " is new " & To_String
                             (UTypes (UTypes (UTI).Parent).Name)
                           & " with record"
                         else " is tagged record"));
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
      Spec_Decl := False;
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
      Exported    : Boolean := False;
      Hdr   : Unbounded_String;
      Impl_Nm : Unbounded_String;  --  generated Ada name (methods, M13)
      POpen : array (1 .. Max_Params) of Boolean := (others => False);

      --  Ada type name for formal parameter I (M12): open arrays map to
      --  the unconstrained String / shared numeric base; named user
      --  types use their Ada name; otherwise the scalar Ada type.
      function Formal_Ada_Type (I : Natural) return String is
      begin
         if I = 1 and then Recv_UT /= 0 then
            --  method receiver: class-wide view of the bound record (M13)
            return To_String (UTypes (Recv_UT).Name) & "'Class";
         end if;
         if POpen (I) then
            if PTyp (I) = T_Char then
               return "String";
            elsif PTyp (I) = T_Int then
               return "O2c_Int_Arr";
            else
               return "O2c_Bool_Arr";
            end if;
         elsif PUT (I) /= 0 then
            return To_String (UTypes (PUT (I)).Name);
         else
            return Ada_Type (PTyp (I));
         end if;
      end Formal_Ada_Type;
   begin
      if Recv_UT /= 0 then
         --  type-bound procedure: receiver is formal parameter #1
         Impl_Nm := To_Unbounded_String (Method_Impl_Name (Name, Recv_UT));
         N_Par := 1;
         PName (1) := Recv_Nm;
         PTyp (1) := T_Int;
         PUT (1) := Recv_UT;
         PRef (1) := Recv_Var;
         POpen (1) := False;
      else
         Impl_Nm := To_Unbounded_String (Name);
      end if;
      Seen_Proc := True;
      Next;                       --  past the procedure name
      Exported := False;
      if Cur.Kind = Lex.Tok_Star then
         Exported := True;        --  export mark (M19)
         Next;
      end if;
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
               if Cur.Kind = Lex.Tok_Array then
                  --  open array formal: ARRAY OF <scalar> (M12)
                  Next;             --  past ARRAY
                  Expect (Lex.Tok_Of, "'OF'");
                  Next;
                  if Cur.Kind /= Lex.Tok_Ident then
                     raise O2c_Error with "an element type expected after "
                       & "ARRAY OF (line " & Natural'Image (Cur.Line) & ")";
                  end if;
                  PTyp (N_Par) := Builtin_Type_Of (Cur.Text (1 .. Cur.Len));
                  if PTyp (N_Par) = T_Str then
                     raise O2c_Error with "open array element types: INTEGER/"
                       & "BOOLEAN/CHAR only ('"
                       & Cur.Text (1 .. Cur.Len) & "')";
                  end if;
                  POpen (N_Par) := True;
                  if PTyp (N_Par) = T_Int then
                     Used_Int_Arr := True;
                  elsif PTyp (N_Par) = T_Bool then
                     Used_Bool_Arr := True;
                  end if;
               else
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
                       Ret => Is_Function, Exp => Exported, others => <>);
      for I in 1 .. N_Par loop
         Syms (N_Sym).P (I) :=
           (Name => PName (I), Typ => PTyp (I), By_Ref => PRef (I),
            UT => PUT (I), Open => POpen (I));
      end loop;
      if Recv_UT /= 0 then
         for B in 1 .. N_Bound loop
            if Bounds (B).RecUT = Recv_UT
              and then To_String (Bounds (B).Name) = Name
            then
               raise O2c_Error with "method '" & Name
                 & "' is already declared on type "
                 & To_String (UTypes (Recv_UT).Name);
            end if;
         end loop;
         N_Bound := N_Bound + 1;
         Bounds (N_Bound) :=
           (Name => To_Unbounded_String (Name), RecUT => Recv_UT,
            SymIdx => N_Sym);
      end if;

      --  parameters are in scope for the body (popped after it)
      Param_Base := N_Sym;
      for I in 1 .. N_Par loop
         N_Sym := N_Sym + 1;
         Syms (N_Sym) := (Kind => S_Var, Typ => PTyp (I), UT => PUT (I),
                          Open_Arr => POpen (I), By_Ref => PRef (I),
                          Name => PName (I), others => <>);
      end loop;

      Hdr := Hdr & "   " & (if Is_Function then "function " else "procedure ")
        & To_String (Impl_Nm);
      if N_Par > 0 then
         Hdr := Hdr & " (";
         for I in 1 .. N_Par loop
            if I > 1 then
               Hdr := Hdr & "; ";
            end if;
            Hdr := Hdr & To_String (PName (I))
              & (if PRef (I) then " : in out " else " : ")
              & Formal_Ada_Type (I);
         end loop;
         Hdr := Hdr & ")";
      end if;
      if Is_Function then
         Hdr := Hdr & " return "
           & (if Ret_UT /= 0 then To_String (UTypes (Ret_UT).Name)
              else Ada_Type (Ret_Typ));
      end if;
      if Exported and then Recv_UT /= 0 then
         --  M20c: exported type-bound method.  Its dispatcher is
         --  exported from the package spec; plain procedures keep the
         --  M19/M20b path below.
         if not UTypes (Recv_UT).ExpT then
            raise O2c_Error with "type-bound procedure '" & Name
              & "' can be exported only on an exported type (M20c)";
         end if;
         for I in 2 .. N_Par loop
            if POpen (I) then
               raise O2c_Error with "exported method '" & Name
                 & "': open ARRAY parameters are not exportable yet "
                 & "(M20c)";
            end if;
            if PTyp (I) = T_Set then
               raise O2c_Error with "exported method '" & Name
                 & "': SET parameters are not exportable (M20c)";
            end if;
            if PUT (I) /= 0 then
               if UTypes (PUT (I)).Imported
                 or else not UTypes (PUT (I)).ExpT
               then
                  raise O2c_Error with "exported method '" & Name
                    & "': parameters may use only this module's exported "
                    & "types (M20c)";
               end if;
               if UTypes (PUT (I)).Is_Rec and then not PRef (I) then
                  raise O2c_Error with "exported method '" & Name
                    & "': RECORD parameters must be declared VAR";
               end if;
               if not (UTypes (PUT (I)).Is_Rec
                       or else UTypes (PUT (I)).Is_Ptr)
               then
                  raise O2c_Error with "exported method '" & Name
                    & "': ARRAY parameters are not exportable yet (M20c)";
               end if;
            end if;
         end loop;
         if Is_Function then
            if Ret_UT /= 0 then
               if UTypes (Ret_UT).Imported
                 or else not UTypes (Ret_UT).ExpT
               then
                  raise O2c_Error with "exported method function '" & Name
                    & "' must return a scalar or this module's exported "
                    & "POINTER type (M20c)";
               end if;
               if not UTypes (Ret_UT).Is_Ptr then
                  raise O2c_Error with "function return types: "
                    & "INTEGER/BOOLEAN/CHAR or a POINTER type ('" & Name
                    & "')";
               end if;
            elsif not Scalar_Exportable (Ret_Typ) then
               raise O2c_Error with "exported method function '" & Name
                 & "' must return INTEGER/LONGINT/REAL/CHAR/BOOLEAN "
                 & "or an exported POINTER (M20c)";
            end if;
         end if;
      elsif Exported then
         --  M19/M20b: exported procedures may take scalars and this
         --  module's exported RECORD (VAR) / POINTER types, and return
         --  scalars or an exported POINTER type.
         if Recv_UT /= 0 then
            raise O2c_Error with "type-bound procedures cannot be "
              & "exported (M20b; '" & Name & "')";
         end if;
         for I in 1 .. N_Par loop
            if POpen (I) then
               raise O2c_Error with "exported procedure '" & Name
                 & "': open ARRAY parameters are not exportable yet "
                 & "(M20c)";
            end if;
            if PTyp (I) = T_Set then
               raise O2c_Error with "exported procedure '" & Name
                 & "': SET parameters are not exportable (M20b)";
            end if;
            if PUT (I) /= 0 then
               if UTypes (PUT (I)).Imported then
                  raise O2c_Error with "exported procedure '" & Name
                    & "': parameters may use only this module's exported "
                    & "types (M20b)";
               end if;
               if not UTypes (PUT (I)).ExpT then
                  raise O2c_Error with "exported procedure '" & Name
                    & "': parameter type '" & To_String (UTypes (PUT (I)).Name)
                    & "' is not exported";
               end if;
               if UTypes (PUT (I)).Is_Rec and then not PRef (I) then
                  raise O2c_Error with "exported procedure '" & Name
                    & "': RECORD parameters must be declared VAR";
               end if;
               if not (UTypes (PUT (I)).Is_Rec
                       or else UTypes (PUT (I)).Is_Ptr)
               then
                  raise O2c_Error with "exported procedure '" & Name
                    & "': ARRAY parameters are not exportable yet (M20c)";
               end if;
            end if;
         end loop;
         if Is_Function then
            if Ret_UT /= 0 then
               if UTypes (Ret_UT).Imported
                 or else not UTypes (Ret_UT).ExpT
               then
                  raise O2c_Error with "exported function '" & Name
                    & "' must return a scalar or this module's exported "
                    & "POINTER type (M20b)";
               end if;
               if not UTypes (Ret_UT).Is_Ptr then
                  raise O2c_Error with "function return types: "
                    & "INTEGER/BOOLEAN/CHAR or a POINTER type ('" & Name
                    & "')";
               end if;
            elsif not Scalar_Exportable (Ret_Typ) then
               raise O2c_Error with "exported function '" & Name
                 & "' must return INTEGER/LONGINT/REAL/CHAR/BOOLEAN "
                 & "or an exported POINTER (M19)";
            end if;
         end if;
         if Pkg_Mode then
            Append_Spec (To_String (Hdr) & ";");
            declare
               E : X_Entry :=
                 (Kind => S_Proc, Typ => Ret_Typ, Params => N_Par,
                  Ret => Is_Function,
                  Name => To_Unbounded_String (Name), others => <>);
            begin
               for I in 1 .. N_Par loop
                  E.P (I) := (Name => PName (I),
                              Typ => (if PUT (I) = 0 then PTyp (I)
                                      else T_Int),
                              UT => 0, By_Ref => PRef (I), Open => False);
                  if PUT (I) /= 0 then
                     E.P_Nm (I) := To_Unbounded_String
                       (QName (To_String (Mod_Name),
                               To_String (UTypes (PUT (I)).Name)));
                  end if;
               end loop;
               if Ret_UT /= 0 then
                  E.Ret_Nm := To_Unbounded_String
                    (QName (To_String (Mod_Name),
                            To_String (UTypes (Ret_UT).Name)));
               end if;
               X_Add (To_String (Mod_Name), E);
            end;
         end if;
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
      Append_Decl ("   end " & To_String (Impl_Nm) & ";");
      if Recv_UT /= 0 and then Is_Function then
         --  method function: dispatcher spec (its body is emitted once
         --  every method is known, in Emit_Dsp_Bodies)
         declare
            Found : Boolean := False;
         begin
            for D in 1 .. N_Dsp loop
               if Dsps (D).BRec = Recv_UT
                 and then To_String (Dsps (D).MName) = Name
               then
                  Found := True;
               end if;
            end loop;
            if not Found then
               N_Dsp := N_Dsp + 1;
               Dsps (N_Dsp) := (MName => To_Unbounded_String (Name),
                                BRec => Recv_UT, SymIdx => Param_Base);
               --  M20c: an exported method function's dispatcher spec
               --  goes into the package spec so importers can call it.
               if Pkg_Mode and then UTypes (Recv_UT).ExpT and then Exported
               then
                  Append_Spec ("   " & Dsp_Hdr (Name, Recv_UT, Param_Base)
                               & ";");
               else
                  Append_Decl ("   " & Dsp_Hdr (Name, Recv_UT, Param_Base)
                               & ";");
               end if;
            end if;
         end;
      end if;

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

   procedure Parse_With is
      --  WITH p: T DO ... END (M13): narrows a POINTER variable's
      --  guarded member access to record type T (a view conversion is
      --  emitted per member use; a mismatched tag raises at runtime).
      VName : String (1 .. 64);
      V_Len : Natural;
      Idx   : Natural;
      GT    : Natural;
   begin
      Next;                       --  WITH
      if Cur.Kind /= Lex.Tok_Ident then
         raise O2c_Error with "a guarded POINTER variable expected after "
           & "WITH (line " & Natural'Image (Cur.Line) & ")";
      end if;
      V_Len := Cur.Len;
      VName (1 .. V_Len) := Cur.Text (1 .. V_Len);
      Idx := Find (VName (1 .. V_Len));
      if Idx = 0 or else Syms (Idx).Kind /= S_Var
        or else Syms (Idx).UT = 0
        or else not UTypes (Syms (Idx).UT).Is_Ptr
      then
         raise O2c_Error with "WITH guards a POINTER variable ('"
           & VName (1 .. V_Len) & "' is not one) (line "
           & Natural'Image (Cur.Line) & ")";
      end if;
      Next;
      Expect (Lex.Tok_Colon, "':' in the WITH guard");
      Next;
      if Cur.Kind /= Lex.Tok_Ident then
         raise O2c_Error with "a record type expected in the WITH guard "
           & "(line " & Natural'Image (Cur.Line) & ")";
      end if;
      GT := Find_UT (Cur.Text (1 .. Cur.Len));
      if GT = 0 or else not UTypes (GT).Is_Rec
        or else not Rec_Descends (GT, UTypes (Syms (Idx).UT).Ptr_Tgt)
      then
         raise O2c_Error with "'" & Cur.Text (1 .. Cur.Len)
           & "' is not an extension of the POINTER's record type "
           & To_String (UTypes (UTypes (Syms (Idx).UT).Ptr_Tgt).Name);
      end if;
      Next;
      Expect (Lex.Tok_Do, "'DO'");
      Next;
      G_N := G_N + 1;
      G_Nm (G_N) := To_Unbounded_String (VName (1 .. V_Len));
      G_Rec (G_N) := GT;
      declare
         Before : constant Natural := Length (Body_Buf);
      begin
         Statement_Seq;              --  until END
         if Length (Body_Buf) = Before then
            Append_Body ("         null;");
         end if;
      end;
      G_N := G_N - 1;
      Expect (Lex.Tok_End, "'END' closing the WITH");
      Next;
   end Parse_With;

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
                  elsif Cur_Ret_Type = T_Long and then V.Typ = T_Int
                    and then V.Lit
                  then
                     null;            --  literal widens (M17)
                  elsif Cur_Ret_Type = T_Real and then V.Typ = T_Int then
                     V.Text := To_Unbounded_String
                       ("Float (" & To_String (V.Text) & ")");
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
         elsif Cur.Kind = Lex.Tok_With then
            Parse_With;
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
            elsif Imported_Mod (Head (1 .. H_Len)) then
               --  imported module member (M19): exported procedure call
               --  or exported scalar VARIABLE write.
               declare
                  MNm  : constant String := Head (1 .. H_Len);
                  MName : Unbounded_String;
                  XI    : Natural;
               begin
                  Next;          --  past the module name
                  Expect (Lex.Tok_Dot, "'.'");
                  Next;
                  Expect (Lex.Tok_Ident, "a member name");
                  MName := To_Unbounded_String (Cur.Text (1 .. Cur.Len));
                  Next;
                  XI := Find_X (MNm, To_String (MName));
                  if XI = 0 then
                     raise O2c_Error with "'" & MNm & "."
                       & To_String (MName) & "' is not exported by module "
                       & MNm;
                  end if;
                  if Xs (XI).Kind = S_Proc then
                     if Xs (XI).Ret then
                        raise O2c_Error with "'" & MNm & "."
                          & To_String (MName)
                          & "' is a function; use its value (line "
                          & Natural'Image (Cur.Line) & ")";
                     end if;
                     if Cur.Kind = Lex.Tok_LParen then
                        Next;
                        declare
                           Args : array (1 .. Max_Params)
                             of Unbounded_String;
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
                                   Parse_Actual (X_Formal (XI, N_A));
                              begin
                                 Args (N_A) := A.Text;
                              end;
                              exit when Cur.Kind /= Lex.Tok_Comma;
                              Next;
                           end loop;
                           if N_A /= Xs (XI).Params then
                              raise O2c_Error with MNm & "."
                                & To_String (MName) & " expects "
                                & Natural'Image (Xs (XI).Params)
                                & " argument(s), got "
                                & Natural'Image (N_A);
                           end if;
                           Expect (Lex.Tok_RParen, "')'");
                           Next;
                           Call := Call & MNm & "." & To_String (MName)
                             & " (";
                           for I in 1 .. N_A loop
                              if I > 1 then
                                 Call := Call & ", ";
                              end if;
                              Call := Call & Args (I);
                           end loop;
                           Call := Call & ");";
                           Append_Body ("      " & To_String (Call));
                        end;
                     else
                        if Xs (XI).Params /= 0 then
                           raise O2c_Error with "'" & MNm & "."
                             & To_String (MName) & "' needs arguments";
                        end if;
                        Append_Body ("      " & MNm & "."
                                     & To_String (MName) & ";");
                     end if;
                  elsif Xs (XI).Kind = S_Var then
                     if Cur.Kind /= Lex.Tok_Assign then
                        raise O2c_Error with "'" & MNm & "."
                          & To_String (MName)
                          & "' is a VARIABLE; assign to it or read it in "
                          & "an expression (line "
                          & Natural'Image (Cur.Line) & ")";
                     end if;
                     Next;
                     declare
                        V : Expr_Rec := Parse_Expr;
                     begin
                        if Xs (XI).Typ = T_Real then
                           if V.Typ = T_Int then
                              Append_Body ("      " & MNm & "."
                                           & To_String (MName)
                                           & " := Float ("
                                           & To_String (V.Text) & ");");
                           elsif V.Typ = T_Real then
                              Append_Body ("      " & MNm & "."
                                           & To_String (MName)
                                           & " := " & To_String (V.Text)
                                           & ";");
                           else
                              raise O2c_Error with "type mismatch assigning "
                                & MNm & "." & To_String (MName);
                           end if;
                        elsif V.Typ = T_Str
                          or else (Xs (XI).Typ /= V.Typ
                                   and then not (Xs (XI).Typ = T_Long
                                                 and then V.Typ = T_Int
                                                 and then V.Lit))
                        then
                           raise O2c_Error with "type mismatch assigning "
                             & MNm & "." & To_String (MName);
                        else
                           Append_Body ("      " & MNm & "."
                                        & To_String (MName) & " := "
                                        & To_String (V.Text) & ";");
                        end if;
                     end;
                  else
                     raise O2c_Error with "cannot assign to the constant '"
                       & MNm & "." & To_String (MName) & "'";
                  end if;
               end;
            else
            Idx := Find (Head (1 .. H_Len));
            Next;
            if (Cur.Kind = Lex.Tok_Caret or else Cur.Kind = Lex.Tok_LBracket
                or else Cur.Kind = Lex.Tok_Dot)
              and then Idx /= 0
              and then Syms (Idx).Kind = S_Var
              and then Syms (Idx).UT /= 0
            then
               --  designator LHS through the engine (M16): '.field' /
               --  '^' deref / '[i]' chains over record, pointer and
               --  array values, ending on a scalar or pointer leaf.
               --  A '.' member that is a type-bound method is a call.
               declare
                  U   : constant Natural := Syms (Idx).UT;
                  Urec : constant Natural :=
                    (if UTypes (U).Is_Ptr then UTypes (U).Ptr_Tgt else U);
               begin
                  if Cur.Kind = Lex.Tok_Dot then
                     --  type-bound method (procedure) call on the
                     --  receiver (peek the member name)
                     declare
                        T1 : Lex.Token := Lex.Peek_Token;
                     begin
                        if T1.Kind = Lex.Tok_Ident then
                           declare
                              BI : constant Natural :=
                                Bound_Find (Urec, T1.Text (1 .. T1.Len));
                           begin
                              if BI /= 0 then
                                 if Syms (Bounds (BI).SymIdx).Ret then
                                    raise O2c_Error with "method '"
                                      & T1.Text (1 .. T1.Len)
                                      & "' is a function; use its value "
                                      & "(line "
                                      & Natural'Image (Cur.Line) & ")";
                                 end if;
                                 Next;      --  past '.'
                                 Expect (Lex.Tok_Ident, "a method name");
                                 declare
                                    Rtxt : constant String :=
                                      (if UTypes (U).Is_Ptr
                                       then Head (1 .. H_Len) & ".all"
                                       else Head (1 .. H_Len));
                                 begin
                                    Next;   --  past the method name
                                    Emit_Method_Call
                                      (BI, Rtxt,
                                       (if UTypes (U).Is_Ptr
                                        then UTypes (U).Ptr_Tgt
                                        else 0));
                                 end;
                              end if;
                              if BI = 0 and then UTypes (Urec).Imported then
                                 --  M20c: method on an imported record
                                 --  type: call the exported dispatcher
                                 declare
                                    Ownr : constant String :=
                                      UT_Owner (Urec);
                                    XMI  : constant Natural :=
                                      XM_Bound (Ownr, Urec,
                                                T1.Text (1 .. T1.Len));
                                 begin
                                    if XMI /= 0 then
                                       if XMs (XMI).Ret then
                                          raise O2c_Error with "method '"
                                            & T1.Text (1 .. T1.Len)
                                            & "' is a function; use its "
                                            & "value (line "
                                            & Natural'Image (Cur.Line)
                                            & ")";
                                       end if;
                                       Next;    --  past '.'
                                       Expect (Lex.Tok_Ident,
                                               "a method name");
                                       declare
                                          Rtxt : constant String :=
                                            (if UTypes (U).Is_Ptr
                                             then Head (1 .. H_Len) & ".all"
                                             else Head (1 .. H_Len));
                                          DNm : constant String :=
                                            T1.Text (1 .. T1.Len);
                                          RNm : constant String :=
                                            To_String (XMs (XMI).RecN);
                                          ArgsT : Unbounded_String;
                                          Call  : Unbounded_String;
                                          N_A   : Natural := 0;
                                       begin
                                          Next;  --  past the method name
                                          if Cur.Kind = Lex.Tok_LParen then
                                             Next;
                                             loop
                                                exit when
                                                  Cur.Kind =
                                                    Lex.Tok_RParen;
                                                N_A := N_A + 1;
                                                if N_A > XMs (XMI).Params
                                                then
                                                   raise O2c_Error with
                                                     "method '" & DNm
                                                     & "' expects "
                                                     & Natural'Image
                                                       (XMs (XMI).Params)
                                                     & " argument(s)";
                                                end if;
                                                declare
                                                   A : Expr_Rec :=
                                                     Parse_Actual
                                                       (XM_Formal
                                                          (XMI, N_A));
                                                begin
                                                   if N_A > 1 then
                                                      ArgsT := ArgsT & ", ";
                                                   end if;
                                                   ArgsT := ArgsT & A.Text;
                                                end;
                                                exit when
                                                  Cur.Kind /=
                                                    Lex.Tok_Comma;
                                                Next;
                                             end loop;
                                             if N_A /= XMs (XMI).Params then
                                                raise O2c_Error with
                                                  "method '" & DNm
                                                  & "' expects "
                                                  & Natural'Image
                                                    (XMs (XMI).Params)
                                                  & " argument(s), got "
                                                  & Natural'Image (N_A);
                                             end if;
                                             Expect (Lex.Tok_RParen,
                                                     "')'");
                                             Next;
                                          elsif XMs (XMI).Params /= 0 then
                                             raise O2c_Error with "method '"
                                               & DNm & "' needs arguments";
                                          end if;
                                          Call := Call & Ownr & "." & DNm
                                            & "_Disp_O2c_" & RNm & " ("
                                            & Rtxt;
                                          if N_A > 0 then
                                             Call := Call & ", "
                                               & ArgsT;
                                          end if;
                                          Call := Call & ");";
                                          Append_Body ("      "
                                                       & To_String (Call));
                                       end;
                                    end if;
                                 end;
                              end if;
                           end;
                        end if;
                     end;
                  end if;
                  if Cur.Kind = Lex.Tok_Caret
                    or else Cur.Kind = Lex.Tok_LBracket
                    or else Cur.Kind = Lex.Tok_Dot
                  then
                     --  the '.' was a field (not a method): parse the
                     --  chain and assign to its scalar/pointer leaf
                     declare
                        D : Desig := Parse_Rec_Ptr_Chain (Head (1 .. H_Len),
                                                          U);
                     begin
                        Expect (Lex.Tok_Assign, "':='");
                        Next;
                        if D.K = D_Scalar then
                           if D.Sc = T_Char and then Cur.Kind = Lex.Tok_String
                             and then Cur.Len = 1
                           then
                              Append_Body ("      " & To_String (D.Text)
                                           & " := '" & Cur.Text (1 .. 1)
                                           & "';");
                              Next;
                           else
                              declare
                                 V : Expr_Rec := Parse_Expr;
                              begin
                                 if V.Typ /= D.Sc or else V.Typ = T_Str then
                                    raise O2c_Error with "type mismatch "
                                      & "assigning " & To_String (D.Text);
                                 end if;
                                 Append_Body ("      " & To_String (D.Text)
                                              & " := " & To_String (V.Text)
                                              & ";");
                              end;
                           end if;
                        elsif D.K = D_Ptr then
                           Assign_Pointer (To_String (D.Text), D.UT);
                        else
                           raise O2c_Error with "cannot assign a whole "
                             & "char-array here; index it (line "
                             & Natural'Image (Cur.Line) & ")";
                        end if;
                     end;
                  end if;
               end;
            elsif Cur.Kind = Lex.Tok_LBracket and then Idx /= 0
              and then Syms (Idx).Kind = S_Var
              and then Syms (Idx).Open_Arr
            then
               --  element write through an ARRAY OF parameter (M12)
               if not Syms (Idx).By_Ref then
                  raise O2c_Error with "cannot assign elements of a value "
                    & "ARRAY OF parameter ('" & Head (1 .. H_Len)
                    & "', line " & Natural'Image (Cur.Line) & ")";
               end if;
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
                  if Syms (Idx).Typ = T_Char then
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
                     if V.Typ /= Syms (Idx).Typ then
                        raise O2c_Error with "element type mismatch assigning "
                          & Head (1 .. H_Len);
                     end if;
                     Append_Body ("      " & Head (1 .. H_Len) & " ("
                                  & To_String (Ix.Text) & ") := "
                                  & To_String (V.Text) & ";");
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
                  Used_Console := True;
                  Next;
                  if Member = "Ln" then
                     Append_Body ("      Aegir_User.Console.Put_Line ("""");");
                  elsif Member = "String" or else Member = "Int"
                    or else Member = "Real"
                  then
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
                     elsif Member = "Int" then
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
                     else
                        --  Out.Real (M18)
                        declare
                           A : Expr_Rec := Parse_Expr;
                        begin
                           if A.Typ /= T_Real then
                              raise O2c_Error
                                with "Out.Real needs a REAL argument";
                           end if;
                           M := A.Text;
                           Used_Real := True;
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
                     elsif Member = "Int" then
                        Append_Body ("      O2c_Put_Int (" & To_String (M)
                                     & ");");
                     else
                        Append_Body ("      O2c_Put_Real (" & To_String (M)
                                     & ");");
                     end if;
                  else
                     raise O2c_Error with "Out supports String/Int/Real/"
                       & "Ln only (found Out." & Member & ")";
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
                     if Syms (Idx).Typ = T_Real then
                        if V.Typ = T_Int then
                           Append_Body ("      " & Head (1 .. H_Len)
                                        & " := Float (" & To_String (V.Text)
                                        & ");");
                        elsif V.Typ = T_Real then
                           Append_Body ("      " & Head (1 .. H_Len)
                                        & " := " & To_String (V.Text) & ";");
                        else
                           raise O2c_Error with "type mismatch assigning "
                             & Head (1 .. H_Len);
                        end if;
                     elsif V.Typ = T_Str
                       or else (Syms (Idx).Typ /= V.Typ
                                and then not (Syms (Idx).Typ = T_Long
                                              and then V.Typ = T_Int
                                              and then V.Lit))
                     then
                        raise O2c_Error with "type mismatch assigning "
                          & Head (1 .. H_Len);
                     else
                        Append_Body ("      " & Head (1 .. H_Len) & " := "
                                     & To_String (V.Text) & ";");
                     end if;
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

      procedure XM_Add (E : XM_Entry) is
   begin
      N_XM := N_XM + 1;
      if N_XM > XMs'Last then
         raise O2c_Error with "too many exported methods";
      end if;
      XMs (N_XM) := E;
   end XM_Add;

   --  M20c exporter side: for every exported type-bound method of the
   --  module just parsed, register its dispatcher in the catalog and,
   --  for procedure methods, emit the dispatcher spec (package spec)
   --  and body (package body).  Function-method dispatchers come from
   --  the existing machinery (their specs route to the spec when
   --  exported); the catalog entry lets importers resolve both kinds.
   procedure Capture_Methods is
   begin
      for Bd in 1 .. N_Bound loop
         declare
            SIdx : constant Natural := Bounds (Bd).SymIdx;
            B    : constant Natural := Bounds (Bd).RecUT;
            DN   : constant String := To_String (Bounds (Bd).Name);
         begin
            if not (UTypes (B).ExpT and then Syms (SIdx).Exp) then
               null;
            else
               declare
                  E : XM_Entry :=
                    (MName => Bounds (Bd).Name,
                     RecN => UTypes (B).Name,
                     Ret => Syms (SIdx).Ret,
                     Typ => Syms (SIdx).Typ,
                     Params => Syms (SIdx).Params - 1,
                     others => <>);
               begin
                  for I in 2 .. Syms (SIdx).Params loop
                     E.P (I - 1) := Syms (SIdx).P (I);
                     E.P (I - 1).UT := 0;
                     if Syms (SIdx).P (I).UT /= 0 then
                        E.P_Nm (I - 1) := To_Unbounded_String
                          (QName (To_String (Mod_Name),
                                  To_String
                                    (UTypes (Syms (SIdx).P (I).UT).Name)));
                        E.P (I - 1).Typ := T_Int;
                     end if;
                  end loop;
                  if Syms (SIdx).Ret and then Syms (SIdx).UT /= 0 then
                     E.Ret_Nm := To_Unbounded_String
                       (QName (To_String (Mod_Name),
                               To_String (UTypes (Syms (SIdx).UT).Name)));
                  end if;
                  E.Owner := To_Unbounded_String (To_String (Mod_Name));
                  XM_Add (E);
               end;
               if not Syms (SIdx).Ret then
                  --  procedure method: export the dispatcher wrapper
                  --  (spec plus body carrying the tag chain)
                  declare
                     Rcvr : constant String :=
                       To_String (Syms (SIdx).P (1).Name);
                     Hdr  : constant String := Dsp_Hdr_P (DN, B, SIdx);
                     ArgL : Unbounded_String;
                     Cand : array (1 .. Max_Bound) of Natural :=
                       (others => 0);
                     N_C  : Natural := 0;
                  begin
                     for I in 2 .. Syms (SIdx).Params loop
                        if I > 2 then
                           ArgL := ArgL & ", ";
                        end if;
                        ArgL := ArgL & To_String (Syms (SIdx).P (I).Name);
                     end loop;
                     for X in 1 .. N_UT loop
                        if UTypes (X).Is_Rec and then X /= B
                          and then Rec_Descends (X, B)
                        then
                           for Bd2 in 1 .. N_Bound loop
                              if Bounds (Bd2).RecUT = X
                                and then To_String (Bounds (Bd2).Name) = DN
                              then
                                 declare
                                    Pos : Positive := N_C + 1;
                                 begin
                                    while Pos > 1 and then
                                      Rec_Depth (X) > Rec_Depth (Cand (Pos - 1))
                                    loop
                                       Cand (Pos) := Cand (Pos - 1);
                                       Pos := Pos - 1;
                                    end loop;
                                    Cand (Pos) := X;
                                 end;
                                 N_C := N_C + 1;
                              end if;
                           end loop;
                        end if;
                     end loop;
                     Append_Spec ("   " & Hdr & ";");
                     Append_Decl ("   " & Hdr & " is");
                     Append_Decl ("   begin");
                     if N_C > 0 then
                        for I in 1 .. N_C loop
                           Append_Decl ("      if " & Rcvr & " in "
                                        & To_String (UTypes (Cand (I)).Name)
                                        & "'Class then");
                           Append_Decl ("         "
                                        & Method_Impl_Name (DN, Cand (I))
                                        & " (" & To_String
                                            (UTypes (Cand (I)).Name) & " ("
                                        & Rcvr & ")"
                                        & (if Syms (SIdx).Params > 1
                                           then ", " & To_String (ArgL)
                                           else "") & ");");
                        end loop;
                        Append_Decl ("      else");
                     end if;
                     Append_Decl ("         " & Method_Impl_Name (DN, B)
                                  & " (" & Rcvr
                                  & (if Syms (SIdx).Params > 1
                                     then ", " & To_String (ArgL)
                                     else "") & ");");
                     if N_C > 0 then
                        Append_Decl ("      end if;");
                     end if;
                     Append_Decl ("   end " & Dsp_Name (DN, B) & ";");
                  end;
               end if;
            end if;
         end;
      end loop;
   end Capture_Methods;

procedure Compile_Module (Source : String; Is_Lib : Boolean;
                             Main_Txt : out Unbounded_String;
                             Spec_Txt : out Unbounded_String;
                             Body_Txt : out Unbounded_String) is

      --  Shared per-unit preamble items: open-array bases, the SET
      --  type, and the O2c_Put_* console helpers (emitted inside the
      --  declarative region of the main procedure or a package body).
      procedure Emit_Helpers (S : in out Unbounded_String) is
      begin
         if Used_Int_Arr then
            S := S & "   type O2c_Int_Arr is array (Integer range <>) of Integer;"
              & ASCII.LF;
         end if;
         if Used_Bool_Arr then
            S := S & "   type O2c_Bool_Arr is array (Integer range <>) of Boolean;"
              & ASCII.LF;
         end if;
         if Used_Set then
            S := S & "   type O2c_Set is mod 2**32;" & ASCII.LF;
         end if;
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
         if Used_Real then
            S := S & "   procedure O2c_Put_Real (V : Float) is" & ASCII.LF
              & "      IP : Integer;" & ASCII.LF
              & "      FR : Integer;" & ASCII.LF
              & "   begin" & ASCII.LF
              & "      IP := Integer (V - 0.5);" & ASCII.LF
              & "      if V < 0.0 then IP := IP + 1; end if;" & ASCII.LF
              & "      FR := Integer (abs (V - Float (IP)) * 1000.0);"
              & ASCII.LF
              & "      declare" & ASCII.LF
              & "         Img : constant String := Integer'Image (IP);"
              & ASCII.LF
              & "      begin" & ASCII.LF
              & "         if Img (Img'First) = '-' then" & ASCII.LF
              & "            Aegir_User.Console.Put (Img);" & ASCII.LF
              & "         elsif Img (Img'First) = ' ' then" & ASCII.LF
              & "            Aegir_User.Console.Put (Img" & ASCII.LF
              & "              (Img'First + 1 .. Img'Last));" & ASCII.LF
              & "         else" & ASCII.LF
              & "            Aegir_User.Console.Put (Img);" & ASCII.LF
              & "         end if;" & ASCII.LF
              & "      end;" & ASCII.LF
              & "      Aegir_User.Console.Put (""."");" & ASCII.LF
              & "      declare" & ASCII.LF
              & "         D3 : constant String := Character'Val (48 + FR / 100)"
              & ASCII.LF
              & "           & Character'Val (48 + (FR / 10) mod 10)"
              & ASCII.LF
              & "           & Character'Val (48 + FR mod 10);" & ASCII.LF
              & "      begin" & ASCII.LF
              & "         Aegir_User.Console.Put (D3);" & ASCII.LF
              & "      end;" & ASCII.LF
              & "   end O2c_Put_Real;" & ASCII.LF;
         end if;
      end Emit_Helpers;

   begin
      Decl_Buf := Null_Unbounded_String;
      Body_Buf := Null_Unbounded_String;
      Spec_Buf := Null_Unbounded_String;
      Mod_Name := Null_Unbounded_String;
      N_Sym := 0;
      N_UT := 0;
      Loop_Depth := 0;
      Loop_N := 0;
      Used_Int := False;
      Used_CStr := False;
      Used_Int_Arr := False;
      Used_Bool_Arr := False;
      Used_Set := False;
      Used_Real := False;
      Used_Console := False;
      N_Bound := 0;
      Recv_UT := 0;
      G_N := 0;
      N_Dsp := 0;
      N_Imp := 0;
      Seen_Proc := False;
      Pkg_Mode := Is_Lib;

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
         loop
            Expect (Lex.Tok_Ident, "an imported module name");
            declare
               MN : constant String := Cur.Text (1 .. Cur.Len);
            begin
               if MN /= "Out"
                 and then not (Multi_Ok and then Is_Provided (MN))
               then
                  raise O2c_Error with "M19 imports: only Out, plus "
                    & "library modules provided earlier (found '" & MN
                    & "')";
               end if;
               N_Imp := N_Imp + 1;
               if N_Imp > Max_Imports then
                  raise O2c_Error with "too many imports";
               end if;
               Imports (N_Imp) := (Name => To_Unbounded_String (MN));
            end;
            Next;
            exit when Cur.Kind /= Lex.Tok_Comma;
            Next;
         end loop;
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
            if Cur.Kind = Lex.Tok_LParen then
               --  type-bound procedure (M13): PROCEDURE (VAR r: T) Name
               Next;             --  past '('
               Recv_Var := False;
               if Cur.Kind = Lex.Tok_Var then
                  Recv_Var := True;
                  Next;
               end if;
               if Cur.Kind /= Lex.Tok_Ident then
                  raise O2c_Error with "a receiver variable expected "
                    & "(line " & Natural'Image (Cur.Line) & ")";
               end if;
               Recv_Nm := To_Unbounded_String (Cur.Text (1 .. Cur.Len));
               Next;
               Expect (Lex.Tok_Colon, "':' in the receiver clause");
               Next;
               if Cur.Kind /= Lex.Tok_Ident then
                  raise O2c_Error with "a receiver type expected (line "
                    & Natural'Image (Cur.Line) & ")";
               end if;
               Recv_UT := Find_UT (Cur.Text (1 .. Cur.Len));
               if Recv_UT = 0 or else not UTypes (Recv_UT).Is_Rec
                 or else UTypes (Recv_UT).Is_Ptr
               then
                  raise O2c_Error with "the receiver type must be a RECORD "
                    & "type ('" & Cur.Text (1 .. Cur.Len) & "', line "
                    & Natural'Image (Cur.Line) & ")";
               end if;
               Next;
               Expect (Lex.Tok_RParen, "')' after the receiver clause");
               Next;
            else
               Recv_UT := 0;
            end if;
            Decl_Procedure;
            Recv_UT := 0;
         else
            raise O2c_Error with "expected CONST/VAR/TYPE/PROCEDURE/BEGIN/END"
              & " at line " & Natural'Image (Cur.Line);
         end if;
      end loop;

      Check_No_Pending;

      --  method-function dispatchers (M15), now that every method is known
      Emit_Dsp_Bodies;

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

      if Pkg_Mode then
         Capture_Types;           --  validate + register exported types
         Capture_Methods;         --  export type-bound method dispatchers
      end if;

      --  ---- unit assembly (M19) ----
      if not Pkg_Mode then
         --  command module: a standalone Ada main procedure
         declare
            S : Unbounded_String;
         begin
            S := S & "with Aegir_User.Console;" & ASCII.LF;
            if Used_Set then
               S := S & "with Interfaces;" & ASCII.LF;
            end if;
            for I in 1 .. N_Imp loop
               if To_String (Imports (I).Name) /= "Out" then
                  S := S & "with " & To_String (Imports (I).Name) & ";"
                    & ASCII.LF;
               end if;
            end loop;
            S := S & ASCII.LF;
            S := S & "procedure " & To_String (Mod_Name) & " is" & ASCII.LF;
            Emit_Helpers (S);
            S := S & To_String (Decl_Buf);
            S := S & "begin" & ASCII.LF;
            S := S & "   Aegir_User.Console.Set_Endpoint (1);" & ASCII.LF;
            S := S & To_String (Body_Buf);
            S := S & "end " & To_String (Mod_Name) & ";" & ASCII.LF;
            Main_Txt := S;
         end;
      else
         --  library module: an Ada package spec plus body.  The body
         --  carries the module state, private declarations, procedure
         --  bodies and the module initialisation statements (Ada
         --  elaboration runs them before the importer's body).
         Spec_Txt := To_Unbounded_String
           ("package " & To_String (Mod_Name) & " is" & ASCII.LF)
           & Spec_Buf
           & To_Unbounded_String
             ("end " & To_String (Mod_Name) & ";" & ASCII.LF);
         declare
            S : Unbounded_String;
         begin
            if Used_Console then
               S := S & "with Aegir_User.Console;" & ASCII.LF;
            end if;
            if Used_Set then
               S := S & "with Interfaces;" & ASCII.LF;
            end if;
            for I in 1 .. N_Imp loop
               if To_String (Imports (I).Name) /= "Out" then
                  S := S & "with " & To_String (Imports (I).Name) & ";"
                    & ASCII.LF;
               end if;
            end loop;
            if Length (S) > 0 then
               S := S & ASCII.LF;
            end if;
            S := S & "package body " & To_String (Mod_Name) & " is"
              & ASCII.LF;
            Emit_Helpers (S);
            S := S & To_String (Decl_Buf);
            if Length (Body_Buf) > 0 then
               S := S & "begin" & ASCII.LF;
               if Used_Console then
                  S := S & "   Aegir_User.Console.Set_Endpoint (1);"
                    & ASCII.LF;
               end if;
               S := S & To_String (Body_Buf);
            end if;
            S := S & "end " & To_String (Mod_Name) & ";" & ASCII.LF;
            Body_Txt := S;
         end;
      end if;
   end Compile_Module;

   function Compile (Source : String) return String is
      Main_Txt, Spec_Txt, Body_Txt : Unbounded_String;
   begin
      N_X := 0;
      N_Prov := 0;
      Multi_Ok := False;
      Compile_Module (Source, False, Main_Txt, Spec_Txt, Body_Txt);
      return To_String (Main_Txt);
   end Compile;

   function Compile_Multi (Main_Source : String; Libs : Lib_Array;
                           N_Libs : Natural; Count : out Natural)
                           return Unit_Array
   is
      Res : Unit_Array;
      C   : Natural := 0;
      M_T, S_T, B_T : Unbounded_String;

      procedure Add (File : String; T : Unbounded_String) is
      begin
         C := C + 1;
         if C > Res'Last then
            raise O2c_Error with "too many generated units";
         end if;
         Res (C) := (File => To_Unbounded_String (File), Text => T);
      end Add;
   begin
      N_X := 0;
      N_Prov := 0;
      Multi_Ok := True;
      for I in 1 .. N_Libs loop
         Compile_Module (To_String (Libs (I).Text), True,
                         M_T, S_T, B_T);
         Add (Lower (To_String (Mod_Name)) & ".ads", S_T);
         Add (Lower (To_String (Mod_Name)) & ".adb", B_T);
         N_Prov := N_Prov + 1;
         Provided (N_Prov) := Mod_Name;
      end loop;
      Compile_Module (Main_Source, False, M_T, S_T, B_T);
      Add (Lower (To_String (Mod_Name)) & ".adb", M_T);
      Count := C;
      return Res;
   end Compile_Multi;

end O2c_Compiler;
