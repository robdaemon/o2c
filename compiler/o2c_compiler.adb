with Ada.Strings.Unbounded;
with Ada.Text_IO;
with O2c_Lexer;
with O2c_BC;
with Interfaces;

package body O2c_Compiler is

   use Ada.Strings.Unbounded;
   use type O2c_Lexer.Token_Kind;

   package Lex renames O2c_Lexer;

   --  Bytecode backend (M53).  Control-flow hooks need labels and label
   --  ids must be unique across the whole program, so they come from one
   --  counter that only ever grows.
   Bc_Labels : Natural := 0;

   function New_Bc_Label return Natural is
   begin
      Bc_Labels := Bc_Labels + 1;
      return Bc_Labels;
   end New_Bc_Label;

   --  The encoded image of the last bytecode-mode compilation.
   Bc_Image : Unbounded_String;

   function Bytecode_Image return String is
     (To_String (Bc_Image));

   --  T_Ptr and T_Nil are typing sentinels (never reach Ada_Type):
   --  T_Ptr marks a pointer-value operand (Ptr_UT names its pointer
   --  user type), T_Nil marks the NIL literal.
   type EType is (T_Int, T_Bool, T_Str, T_Char, T_Long, T_Set, T_Real,
                  T_Ptr, T_Nil, T_LReal);

   type Expr_Rec is record
      Text   : Unbounded_String;
      Typ    : EType := T_Int;
      CStr   : Boolean := False;   --  whole ARRAY OF CHAR variable value
      Ptr_UT : Natural := 0;       --  pointer user-type index when T_Ptr
      Lit    : Boolean := False;   --  a plain numeric literal (widening)
      --  A constant INTEGER value, folded as the expression is parsed.
      --  The canonical Ada text is NOT parenthesized for arithmetic
      --  ("2 + 3 * 4"), so recovering the value by re-parsing it would
      --  need a second parser with its own precedence - and would get
      --  "2 + 3 * 4" wrong unless it were perfect.  Carrying the value
      --  through the one real parser is both simpler and exact.
      Val    : Integer := 0;
      Folds  : Boolean := False;
   end record;

   Max_Fields : constant := 32;
   Max_UTypes : constant := 32;

   type UField is record
      Name : Unbounded_String;
      Typ  : EType := T_Int;
      UT   : Natural := 0;         --  pointer user-type index for the
                                   --  field (M8); 0 = builtin scalar
      ExpF : Boolean := False;     --  exported field mark 'name*' (M22)
   end record;

   type UField_Array is array (1 .. Max_Fields) of UField;

   type UType is record
      Name    : Unbounded_String;
      Is_Rec  : Boolean := True;
      Is_Ptr  : Boolean := False;   --  POINTER TO (target in Ptr_Tgt)
      Is_Proc : Boolean := False;   --  PROCEDURE type: a value is a proc id
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
      ForcedSpec : Boolean := False; --  private RECORD shown in the spec
                                    --  as an opaque pointer target (M26)
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
      --  A CONST's value, when it is a plain integer literal.  The bytecode
      --  backend has no module slot to load a constant from - a constant is
      --  not storage - so it needs the number itself, and the symbol record
      --  carried only Ada source text for it.  Const_Usable says whether that
      --  text was a literal the VM can push.
      Const_Val : Integer := 0;
      Const_Usable : Boolean := False;
      Bc_Proc : Natural := 0;      --  bytecode procedure id (Begin_Proc)
      Foreign : Unbounded_String;  --  EXTERN: the C symbol this binds to
      Foreign_Native : Natural := 0;  --  the native id it resolves to
      P      : Param_Array := (others => <>);
   end record;

   Syms  : array (1 .. Max_Syms) of Sym := (others => <>);
   N_Sym : Natural := 0;

   --  module imports (M19): the builtin Out plus user library modules
   --  provided earlier in a Compile_Multi run.
   --  M46: raised from 8 with headroom — the demo now imports the
   --  full builtin set plus its own libraries.
   Max_Imports : constant := 32;
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
      VT_Nm  : Unbounded_String;   --  M20f: exported VARIABLE user type
   end record;
   Xs  : array (1 .. Max_X) of X_Entry := (others => <>);
   N_X : Natural := 0;

   Pkg_Mode   : Boolean := False;   --  compiling a library module
   Multi_Ok   : Boolean := False;   --  library imports are available
   Spec_Buf   : Unbounded_String;   --  package spec text (exports)
   Spec_Decl  : Boolean := False;   --  route Append_Decl to Spec_Buf (M20)
   Spec_Withs : array (1 .. 16) of Unbounded_String := (others => <>);
   N_SW   : Natural := 0;          --  modules an exported shape references
   Body_Withs : array (1 .. 16) of Unbounded_String := (others => <>);
   N_BW   : Natural := 0;          --  extra body-only 'with's (shadows)
   Base_In_Spec : Boolean := False; --  O2c_*_Arr bases live in the spec
   RVar_Specs : array (1 .. 16) of Unbounded_String := (others => <>);
   RVar_N : Natural := 0; --  deferred exported RECORD VARIABLE specs (M20f)
   Used_Console : Boolean := False; --  module emits Console calls

   --  exported type catalog (M20): the visible TYPE declarations of
   --  library modules.  References between types are stored by name
   --  (Owner.Type) because each module owns its own UTypes table.
   Max_XT : constant := 64;
   type XT_Field is record
      Name   : Unbounded_String;
      Typ    : EType := T_Int;      --  scalar field type (UT_Nm = "")
      UT_Nm  : Unbounded_String;    --  qualified user type name, if any
      Exp    : Boolean := False;    --  exported field mark (M22)
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
      --  arrays (M20e): fixed length + element type (scalar Elem, or
      --  qualified Elem_Nm for user element types)
      Arr_Len : Integer := 0;
      Elem    : EType := T_Int;
      Elem_Nm : Unbounded_String;
      Opaque  : Boolean := False;   --  pointer to a private record (M26)
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

   --  widened-pointer dispatch shadows (M29): when a library exports
   --  an override of an imported base method, it also exports a shadow
   --  dispatcher on the base view so base-typed pointers held by
   --  importers dispatch to this library's overrides.
   Max_Sh : constant := 64;
   type Sh_Entry is record
      Owner : Unbounded_String;   --  module exporting the shadow
      BOwn  : Unbounded_String;   --  base module (owns base dispatcher)
      BRec  : Unbounded_String;   --  base record (short) name
      MName : Unbounded_String;
   end record;
   Shs : array (1 .. Max_Sh) of Sh_Entry := (others => <>);
   N_Sh : Natural := 0;

   procedure Sh_Add (Owner, BOwn, BRec, MName : String);
   function Sh_Find (BOwn, BRec, MName : String) return Natural;

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
   Foreign_Sym : Unbounded_String;
   Foreign_Id_Val : Natural := 0;

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

   --  Resolve a variable name for the bytecode backend: a frame local of the
   --  procedure being emitted if one is declared, otherwise a module global.
   --  Lookup, never interning - a read must not mint a frame slot, or it
   --  would silently mean uninitialised memory instead of the global.
   --  Called only while Bytecode_Mode is on, since Global raises outside it.
   --  Load and store pick the opcode as well as the slot: a frame local is
   --  LOAD_L/STORE_L against the current frame, a module variable is
   --  LOAD_G/STORE_G against the globals block.  Getting this wrong is
   --  silent - reading a zeroed global instead of a parameter - so it is
   --  one helper rather than a convention at each site.
   procedure Bc_Load (Ada_Name : String) is
      S : constant Integer := O2c_BC.Local_Slot (Ada_Name);
   begin
      if S >= 0 then
         O2c_BC.Load_Local (Natural (S));
      else
         O2c_BC.Load (O2c_BC.Global (Ada_Name));
      end if;
   end Bc_Load;

   procedure Bc_Store (Ada_Name : String) is
      S : constant Integer := O2c_BC.Local_Slot (Ada_Name);
   begin
      if S >= 0 then
         O2c_BC.Store_Local (Natural (S));
      else
         O2c_BC.Store (O2c_BC.Global (Ada_Name));
      end if;
   end Bc_Store;
   Used_Int_Arr  : Boolean := False;  --  need O2c_Int_Arr base (M12)
   Used_Bool_Arr : Boolean := False;  --  need O2c_Bool_Arr base (M12)
   Used_Set      : Boolean := False;  --  need O2c_Set type + Interfaces
   Used_Real     : Boolean := False;  --  need O2c_Put_Real helper (M18)
   Used_LReal    : Boolean := False;  --  need O2c_Put_LReal helper (M47)
   Used_StrCmp   : Boolean := False;  --  need O2c_S_Cmp helper (M33)
   Nested_Depth : Natural := 0;    --  nested PROCEDURE declarations (M32)
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

   --  M24: record that a package spec needs to 'with' module Nm.
   procedure Add_SW (Nm : String) is
   begin
      if Nm = "" or else Nm = "Out"
        or else Nm = To_String (Mod_Name)
      then
         return;
      end if;
      for I in 1 .. N_SW loop
         if To_String (Spec_Withs (I)) = Nm then
            return;
         end if;
      end loop;
      N_SW := N_SW + 1;
      if N_SW > Spec_Withs'Last then
         raise O2c_Error with "too many spec dependencies";
      end if;
      Spec_Withs (N_SW) := To_Unbounded_String (Nm);
   end Add_SW;

   procedure Add_BW (Nm : String) is
   begin
      if Nm = "" then
         return;
      end if;
      for I in 1 .. N_BW loop
         if To_String (Body_Withs (I)) = Nm then
            return;
         end if;
      end loop;
      N_BW := N_BW + 1;
      if N_BW > Body_Withs'Last then
         raise O2c_Error with "too many body dependencies";
      end if;
      Body_Withs (N_BW) := To_Unbounded_String (Nm);
   end Add_BW;

   --  M42: an Oberon identifier that collides with an Ada reserved
   --  word keeps its Oberon spelling everywhere in the language; only
   --  the Ada-side spelling gets a suffix (Ada_Id).
   function Ada_Id (Nm : String) return String is
      L : String (Nm'Range);
   begin
      --  Ada identifiers are case-insensitive, so any casing of an
      --  Ada reserved word needs the Ada-side suffix.
      for I in Nm'Range loop
         if Nm (I) in 'A' .. 'Z' then
            L (I) := Character'Val (Character'Pos (Nm (I)) + 32);
         else
            L (I) := Nm (I);
         end if;
      end loop;
      --  Also mangle names that collide with Ada's predefined types:
      --  a subprogram named String, Integer, ... would hide the type
      --  the generated code depends on.
      if L = "integer" or else L = "float" or else L = "string"
        or else L = "boolean" or else L = "character"
        or else L = "long_integer" or else L = "long_float"
        or else L = "natural" or else L = "positive"
        or else L = "true" or else L = "false"
      then
         return Nm & "_o2c";
      end if;
      if L = "abort" or else L = "abstract" or else L = "accept" or else L = "access" or else L = "aliased" or else L = "all" or else L = "and" or else L = "array" or else L = "at" or else L = "begin" or else L = "body" or else L = "case" or else L = "constant" or else L = "declare" or else L = "delay" or else L = "delta" or else L = "digits" or else L = "do" or else L = "else" or else L = "elsif" or else L = "end" or else L = "entry" or else L = "exception" or else L = "exit" or else L = "for" or else L = "function" or else L = "generic" or else L = "goto" or else L = "if" or else L = "in" or else L = "interface" or else L = "is" or else L = "loop" or else L = "mod" or else L = "new" or else L = "not" or else L = "null" or else L = "of" or else L = "or" or else L = "others" or else L = "out" or else L = "overriding" or else L = "package" or else L = "pragma" or else L = "private" or else L = "procedure" or else L = "protected" or else L = "raise" or else L = "range" or else L = "record" or else L = "rem" or else L = "renames" or else L = "requeue" or else L = "return" or else L = "reverse" or else L = "select" or else L = "separate" or else L = "some" or else L = "subtype" or else L = "synchronized" or else L = "tagged" or else L = "task" or else L = "terminate" or else L = "then" or else L = "type" or else L = "until" or else L = "use" or else L = "when" or else L = "while" or else L = "with" or else L = "xor" then
         return Nm & "_o2c";
      end if;
      return Nm;
   end Ada_Id;

   --  Like Ada_Id, but for a qualified Oberon reference ('Math.Point'):
   --  only the final component is an Ada identifier emitted as-is.
   function Ada_Last (Q : String) return String is
      D : Natural := 0;
   begin
      for I in Q'Range loop
         if Q (I) = '.' then
            D := I;
         end if;
      end loop;
      if D = 0 then
         return Ada_Id (Q);
      end if;
      return Q (Q'First .. D) & Ada_Id (Q (D + 1 .. Q'Last));
   end Ada_Last;

   function Spec_With_Lines return String is
      R : Unbounded_String;
   begin
      for I in 1 .. N_SW loop
         R := R & "with " & Ada_Id (To_String (Spec_Withs (I))) & ";"
           & ASCII.LF;
      end loop;
      return To_String (R);
   end Spec_With_Lines;


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

   --  True for the builtin modules whose members are FFI primitives - the
   --  ones with a native implementation on the Aegir side and nothing in this
   --  compiler.  A call to one of their exported procedures reaches the
   --  imported-module path, which builds Ada text; in bytecode mode that text
   --  is discarded, so the call compiled, ran and silently did nothing.
   --  Their sibling builtins (Strings, Texts, Math...) are real modules and
   --  are not listed here.
   function Is_FFI_Mod (Nm : String) return Boolean is
     (Nm = "Convert" or else Nm = "Env" or else Nm = "Args"
      or else Nm = "Files" or else Nm = "XYplane" or else Nm = "In");

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

   --  M23: deepest exported method bound on Rec's chain, including
   --  imported ancestors (a local extension of an imported record
   --  inherits the module's exported methods).
   function XM_Chain (Rec : Natural; MName : String) return Natural is
      U : Natural := Rec;
   begin
      while U /= 0 loop
         if UTypes (U).Imported then
            declare
               X : constant Natural :=
                 XM_Bound (UT_Owner (U), U, MName);
            begin
               if X /= 0 then
                  return X;
               end if;
            end;
         end if;
         U := UTypes (U).Parent;
      end loop;
      return 0;
   end XM_Chain;

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
        or else T = T_LReal
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

   --  Qualified Ada name of a user type in this module: imported shapes
   --  already carry their Owner.Name form; local ones get the current
   --  module prefix (M24 cross-module composition).
   function Qual_UT (UT : Natural) return String is
      N : constant String := To_String (UTypes (UT).Name);
   begin
      if UTypes (UT).Imported then
         return Ada_Last (N);
      end if;
      return QName (Ada_Id (To_String (Mod_Name)), Ada_Id (N));
   end Qual_UT;

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
              or else not UTypes (UTypes (U).Ptr_Tgt).Is_Rec
            then
               raise O2c_Error with "exported POINTER TO type '"
                 & To_String (UTypes (U).Name)
                 & "' must designate a RECORD of the same module";
            end if;
            if not UTypes (UTypes (U).Ptr_Tgt).ExpT
              and then not UTypes (UTypes (U).Ptr_Tgt).ForcedSpec
            then
               raise O2c_Error with "exported POINTER TO type '"
                 & To_String (UTypes (U).Name)
                 & "' must designate an exported RECORD or a private "
                 & "RECORD declared after it (opaque, M26)";
            end if;
         elsif UTypes (U).Is_Rec then
            if UTypes (U).Is_Ext
              and then (UTypes (U).Parent = 0
                        or else (not UTypes (UTypes (U).Parent).ExpT
                                 and then
                                   not UTypes (UTypes (U).Parent).Imported))
            then
               raise O2c_Error with "exported extension type '"
                 & To_String (UTypes (U).Name)
                 & "' must extend an exported RECORD of this module or of "
                 & "an imported module (M27)";
            end if;
            for F in 1 .. UTypes (U).N_F loop
               declare
                  Fld : UField renames UTypes (U).F (F);
               begin
                  if Fld.UT /= 0 then
                     if not UTypes (Fld.UT).ExpT
                       and then not UTypes (Fld.UT).Imported
                     then
                        raise O2c_Error with "exported RECORD '"
                          & To_String (UTypes (U).Name)
                          & "': field '" & To_String (Fld.Name)
                          & "' must be scalar, an exported type of the "
                          & "same module or an imported exported type "
                          & "(M24)";
                     end if;
                  end if;
               end;
            end loop;
         else
            --  exported fixed ARRAY type (M20e)
            if UTypes (U).Elem_UT /= 0 then
               if not UTypes (UTypes (U).Elem_UT).ExpT
                 and then not UTypes (UTypes (U).Elem_UT).Imported
               then
                  raise O2c_Error with "exported ARRAY type '"
                    & To_String (UTypes (U).Name)
                    & "': element type must be scalar, an exported type "
                    & "of the same module or an imported exported type "
                    & "(M24)";
               end if;
            elsif UTypes (U).Elem = T_Set then
               raise O2c_Error with "exported ARRAY type '"
                 & To_String (UTypes (U).Name)
                 & "': SET elements are not exportable (M20e)";
            end if;
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
               if UTypes (UTypes (U).Ptr_Tgt).ExpT then
                  XT_Tab (N_XT).Ptr_Nm := To_Unbounded_String
                    (Qual_UT (UTypes (U).Ptr_Tgt));
               else
                  XT_Tab (N_XT).Opaque := True;
               end if;
            end if;
            if UTypes (U).Is_Ext then
               XT_Tab (N_XT).Par_Nm := To_Unbounded_String
                 (Qual_UT (UTypes (U).Parent));
            end if;
            if UTypes (U).Is_Rec then
               XT_Tab (N_XT).N_F := UTypes (U).N_F;
               for F in 1 .. UTypes (U).N_F loop
                  declare
                     Fld : UField renames UTypes (U).F (F);
                  begin
                     XT_Tab (N_XT).F (F).Name := Fld.Name;
                     XT_Tab (N_XT).F (F).Exp := Fld.ExpF;
                     if Fld.UT /= 0 then
                        XT_Tab (N_XT).F (F).UT_Nm := To_Unbounded_String
                          (Qual_UT (Fld.UT));
                     else
                        XT_Tab (N_XT).F (F).Typ := Fld.Typ;
                     end if;
                  end;
               end loop;
            elsif not UTypes (U).Is_Ptr then
               --  exported fixed ARRAY type (M20e)
               XT_Tab (N_XT).Arr_Len := UTypes (U).Arr_Len;
               XT_Tab (N_XT).Elem := UTypes (U).Elem;
               if UTypes (U).Elem_UT /= 0 then
                  XT_Tab (N_XT).Elem_Nm := To_Unbounded_String
                    (Qual_UT (UTypes (U).Elem_UT));
               end if;
            end if;
         end if;
      end loop;
      --  M24: exported shapes may reference another module's exported
      --  types; their package specs need 'with' clauses.
      for I in 1 .. N_XT loop
         if To_String (XT_Tab (I).Owner) = To_String (Mod_Name) then
            for F in 1 .. XT_Tab (I).N_F loop
               if Length (XT_Tab (I).F (F).UT_Nm) > 0 then
                  Add_SW (Q_Owner (To_String (XT_Tab (I).F (F).UT_Nm)));
               end if;
            end loop;
            if Length (XT_Tab (I).Elem_Nm) > 0 then
               Add_SW (Q_Owner (To_String (XT_Tab (I).Elem_Nm)));
            end if;
            if Length (XT_Tab (I).Par_Nm) > 0 then
               Add_SW (Q_Owner (To_String (XT_Tab (I).Par_Nm)));
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

      --  Resolve a qualified type reference from an imported shape,
      --  importing its module's types on demand (M24 composition).
      function UT_Ref (Nm : String) return Natural is
         R : Natural := UT_By_Name (Nm);
         D : Natural;
      begin
         if R /= 0 then
            return R;
         end if;
         D := Q_Dot (Nm);
         return Import_Type (Nm (Nm'First .. D - 1),
                             Nm (D + 1 .. Nm'Last));
      end UT_Ref;

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
               if Length (XT_Tab (X).Ptr_Nm) > 0 then
                  UTypes (U).Ptr_Tgt :=
                    UT_Ref (To_String (XT_Tab (X).Ptr_Nm));
               end if;   --  opaque: Ptr_Tgt stays 0 (M26)
            end if;
            if XT_Tab (X).Is_Ext then
               UTypes (U).Parent :=
                 UT_Ref (To_String (XT_Tab (X).Par_Nm));
            end if;
            if XT_Tab (X).Is_Rec then
               UTypes (U).N_F := XT_Tab (X).N_F;
               for F in 1 .. XT_Tab (X).N_F loop
                  UTypes (U).F (F) :=
                    (Name => XT_Tab (X).F (F).Name,
                     Typ => XT_Tab (X).F (F).Typ,
                     UT => (if Length (XT_Tab (X).F (F).UT_Nm) = 0
                            then 0
                            else UT_Ref
                              (To_String (XT_Tab (X).F (F).UT_Nm))),
                     ExpF => XT_Tab (X).F (F).Exp);
               end loop;
            elsif not XT_Tab (X).Is_Ptr then
               --  fixed array shape (M20e)
               UTypes (U).Arr_Len := XT_Tab (X).Arr_Len;
               UTypes (U).Elem := XT_Tab (X).Elem;
               if Length (XT_Tab (X).Elem_Nm) > 0 then
                  UTypes (U).Elem_UT := UT_Ref
                    (To_String (XT_Tab (X).Elem_Nm));
               end if;
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

   --  Scalar slots a record occupies, its parent's fields first: an
   --  extension's layout begins with its ancestors'.
   function Total_Slots (UT : Natural; Depth : Natural := 0) return Natural is
      N : Natural := 0;
   begin
      if UTypes (UT).Arr_Len > 0 then
         if UTypes (UT).Elem = T_Char then
            return (Natural (UTypes (UT).Arr_Len) + 1 + 7) / 8;
         end if;
         if UTypes (UT).Elem = T_Bool then
            --  One byte per element, as a CHAR array, but with no
            --  terminator: a boolean array is a run of values, not a string.
            return (Natural (UTypes (UT).Arr_Len) + 7) / 8;
         end if;
         --  An array of slot-scalars is its length: that is both its
         --  footprint and what a variable of it needs nominating.  A record
         --  has Arr_Len zero and falls through to the field walk.
         return Natural (UTypes (UT).Arr_Len);
      end if;
      if Depth > 8 then
         --  A record containing itself without an intervening pointer would
         --  be infinite; refuse instead of recursing.
         raise O2c_BC.Wrong_Construct with
           "bytecode backend: a record nests too deeply to lay out";
      end if;
      declare
         U : Natural := UT;
      begin
         while U /= 0 loop
            for F in 1 .. UTypes (U).N_F loop
               if UTypes (U).F (F).UT = U then
                  --  Oberon's implicit pointer: a field naming the record it
                  --  sits in is one word, not the record again.  Recursing
                  --  here is what the depth bound below exists to catch, and
                  --  it caught exactly this - a list failed to lay out.
                  N := N + 1;
               elsif UTypes (U).F (F).UT /= 0 then
                  if UTypes (UTypes (U).F (F).UT).Arr_Len > 0 then
                     N := N + Natural (UTypes (UTypes (U).F (F).UT).Arr_Len);
                  elsif not UTypes (UTypes (U).F (F).UT).Is_Ptr then
                     N := N + Total_Slots (UTypes (U).F (F).UT, Depth + 1);
                  else
                     N := N + 1;   --  a pointer is one word
                  end if;
               else
                  N := N + 1;      --  a scalar is one word
               end if;
            end loop;
            U := UTypes (U).Parent;
         end loop;
      end;
      return N;
   end Total_Slots;

   --  Byte offset of field F of record FO, seen through a variable declared
   --  as Base_UT.  Every ancestor's fields between the two come first, which
   --  is what lets an inherited field sit at the offset it has in its
   --  parent - and makes the plain case, FO = Base_UT, come out as the
   --  declaration-order formula it always was.
   --  One descriptor per record type, made on first use.  A type tested
   --  twice must have the same reference, or an object allocated as one and
   --  tested as the other would not match.  Its base is the parent's
   --  reference, which is what makes a test for an ancestor succeed.
   Desc_Cache : array (1 .. Max_UTypes) of Natural := (others => 0);

   --  A record type's method table, built from its ancestors' and then its
   --  own.  An override keeps the slot the ancestor gave the name, which is
   --  what lets DISPATCH resolve by index alone.
   type Mb_Rec is record
      Name : Unbounded_String;
      Proc : Natural := 0;
   end record;
   type Mb_Array is array (1 .. 16) of Mb_Rec;
   type Mtab_Rec is record
      N : Natural := 0;
      M : Mb_Array := (others => <>);
      Ref : Natural := 0;
   end record;
   Mtabs : array (1 .. Max_UTypes) of Mtab_Rec;

   procedure Fill_Table (UT : Natural) is
      U : Natural := UT;
   begin
      if Mtabs (UT).Ref /= 0 then
         return;
      end if;
      Mtabs (UT).Ref := 1;          --  in progress: the chain terminates
      if UTypes (UT).Is_Ext and then UTypes (UT).Parent /= 0 then
         Fill_Table (UTypes (UT).Parent);
         Mtabs (UT).N := Mtabs (UTypes (UT).Parent).N;
         Mtabs (UT).M (1 .. Mtabs (UT).N) :=
           Mtabs (UTypes (UT).Parent).M (1 .. Mtabs (UT).N);
      end if;
      for B in 1 .. N_Bound loop
         if Bounds (B).RecUT = U then
            declare
               Found : Boolean := False;
            begin
               for I in 1 .. Mtabs (UT).N loop
                  if To_String (Mtabs (UT).M (I).Name) =
                    To_String (Bounds (B).Name)
                  then
                     Mtabs (UT).M (I).Proc := Syms (Bounds (B).SymIdx).Bc_Proc;
                     Found := True;
                  end if;
               end loop;
               if not Found and then Mtabs (UT).N < Mtabs (UT).M'Last then
                  Mtabs (UT).N := Mtabs (UT).N + 1;
                  Mtabs (UT).M (Mtabs (UT).N) :=
                    (Name => Bounds (B).Name,
                     Proc => Syms (Bounds (B).SymIdx).Bc_Proc);
               end if;
            end;
         end if;
      end loop;
   end Fill_Table;

   --  Whether any field of a record, or of a record it nests, can hold a
   --  pointer.  The VM's mark phase scans an object's body only when this is
   --  true, so an answer wrong in the false direction would silo an object
   --  from its roots.  Arrays are of slot scalars here, never pointers.
   function Has_Ptrs (U : Natural; Depth : Natural := 0) return Boolean is
   begin
      if U = 0 or else Depth > 8 then
         return False;
      end if;
      for J in 1 .. UTypes (U).N_F loop
         declare
            FT : constant Natural := UTypes (U).F (J).UT;
         begin
            if FT = U then
               return True;                --  Oberon's implicit pointer
            elsif FT /= 0
              and then (UTypes (FT).Is_Ptr
                        or else (UTypes (FT).Arr_Len = 0
                                 and then Has_Ptrs (FT, Depth + 1)))
            then
               return True;
            end if;
         end;
      end loop;
      return False;
   end Has_Ptrs;

   function Desc_For (UT : Natural) return Natural is
   begin
      if Desc_Cache (UT) /= 0 then
         return Desc_Cache (UT);
      end if;
      if O2c_BC.Bytecode_Mode then
         Fill_Table (UT);
         declare
            Ids : O2c_BC.Id_List (1 .. Mtabs (UT).N);
         begin
            for I in 1 .. Mtabs (UT).N loop
               Ids (I) := Mtabs (UT).M (I).Proc;
            end loop;
            if Mtabs (UT).N > 0 then
               Mtabs (UT).Ref := O2c_BC.Method_Table (Ids);
            end if;
         end;
      end if;
      Desc_Cache (UT) := O2c_BC.Desc_Rec
        (Total_Slots (UT) * 8,
         (if UTypes (UT).Is_Ext and then UTypes (UT).Parent /= 0
          then Desc_For (UTypes (UT).Parent)
          else 0),
         (if O2c_BC.Bytecode_Mode then Mtabs (UT).Ref else 0),
         Has_Ptrs (UT));
      return Desc_Cache (UT);
   end Desc_For;

   function Field_Offset (Base_UT : Natural; FO : Natural; F : Natural)
                          return Natural is
      N : Natural := 0;
      --  A pointer base designates its target, so the chain is walked from
      --  there: p^.v has a variable of pointer type and a field owned by the
      --  record.  Without this the walk never reaches the owner and every
      --  field access through a pointer is refused.
      U : Natural := (if UTypes (Base_UT).Is_Ptr
                      then UTypes (Base_UT).Ptr_Tgt
                      else Base_UT);
   begin
      while U /= 0 and then U /= FO loop
         N := N + UTypes (U).N_F;
         U := UTypes (U).Parent;
      end loop;
      if U = 0 then
         --  FO is not on the chain, so nothing can name its offset; say so
         --  rather than guess one.
         raise O2c_BC.Wrong_Construct with
           "bytecode backend: a field's owning record is not on the "
           & "variable's type chain";
      end if;
      return (N + F - 1) * 8;
   end Field_Offset;

   --  True when every field of the record, and of each of its ancestors, is
   --  one the bytecode can reach: a scalar of a type that fits a slot, or a
   --  field naming its own record.
   function Fields_Allowed (U : Natural; Depth : Natural := 0) return Boolean is
      Slot_Scalar : Boolean;
   begin
      if Depth > 8 then
         return False;
      end if;
      for J in 1 .. UTypes (U).N_F loop
         if UTypes (U).F (J).UT = 0 then
            Slot_Scalar := UTypes (U).F (J).Typ = T_Int
              or else UTypes (U).F (J).Typ = T_Char
              or else UTypes (U).F (J).Typ = T_Bool
              or else UTypes (U).F (J).Typ = T_Set
              or else UTypes (U).F (J).Typ = T_Real
              or else UTypes (U).F (J).Typ = T_LReal;
            if not Slot_Scalar then
               return False;
            end if;
         elsif UTypes (U).F (J).UT = U
           or else UTypes (UTypes (U).F (J).UT).Is_Ptr
         then
            null;                  --  one word: a pointer either way
         elsif UTypes (UTypes (U).F (J).UT).Arr_Len > 0 then
            --  a fixed array of slot scalars
            if not (UTypes (UTypes (U).F (J).UT).Elem = T_Int
                    or else UTypes (UTypes (U).F (J).UT).Elem = T_Char
                    or else UTypes (UTypes (U).F (J).UT).Elem = T_Bool
                    or else UTypes (UTypes (U).F (J).UT).Elem = T_Set
                    or else UTypes (UTypes (U).F (J).UT).Elem = T_Real
                    or else UTypes (UTypes (U).F (J).UT).Elem = T_LReal)
            then
               return False;
            end if;
         elsif UTypes (UTypes (U).F (J).UT).Is_Rec then
            if not Fields_Allowed (UTypes (U).F (J).UT, Depth + 1) then
               return False;
            end if;
         else
            return False;
         end if;
      end loop;
      return True;
   end Fields_Allowed;

   function Chain_Fields_Allowed (UT : Natural) return Boolean is
      U : Natural := UT;
   begin
      while U /= 0 loop
         if not Fields_Allowed (U) then
            return False;
         end if;
         U := UTypes (U).Parent;
      end loop;
      return True;
   end Chain_Fields_Allowed;

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
         when T_LReal => return "Long_Float";
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
         return Ada_Last (To_String (UTypes (P.UT).Name));
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
           & (if I = 1 then Ada_Last (To_String (UTypes (B).Name))
                            & "'Class"
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
           & (if I = 1 then Ada_Last (To_String (UTypes (B).Name))
                            & "'Class"
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
                               & Ada_Last (To_String (UTypes (Cand (I)).Name))
                               & "'Class then");
                  Append_Decl ("         return "
                               & Method_Impl_Name (DN, Cand (I)) & " ("
                               & Ada_Last (To_String (UTypes (Cand (I)).Name)) & " ("
                               & Rcvr & ")"
                               & (if NArg > 1
                                  then ", " & To_String (ArgL)
                                  else "")
                               & ");");
               end loop;
               Append_Decl ("      else");
            end if;
            Append_Decl ("         return " & Method_Impl_Name (DN, B)
                         & " (" & Ada_Last (To_String (UTypes (B).Name)) & " (" & Rcvr
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
      elsif Eq_No_Case (Name, "LONGREAL") then
         return T_LReal;          --  M47
      end if;
      return T_Str;               --  sentinel: not a builtin scalar
   end Builtin_Type_Of;

   function Scalar_Init (T : EType) return String is
   begin
      case T is
         when T_Int | T_Long | T_Set => return "0";
         when T_Real | T_LReal => return "0.0";
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
               S := S & Ada_Id (To_String (UTypes (U).F (F).Name))
                 & " => "
                 & (if UTypes (U).F (F).UT = U
                    --  A field that names the record it is a field of is
                    --  Oberon's implicit pointer, and expanding the record
                    --  inside its own initial value recursed forever - a
                    --  STORAGE_ERROR from a five-line program.  Its default
                    --  is null, like any other pointer's.
                    then "null"
                    elsif UTypes (U).F (F).UT /= 0
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

   type Desig_Kind is (D_Scalar, D_Ptr, D_Str, D_Index, D_Field);

   type Desig is record
      Text : Unbounded_String;
      K    : Desig_Kind := D_Scalar;
      Sc   : EType := T_Int;      --  scalar type when D_Scalar
      UT   : Natural := 0;        --  pointer user type when D_Ptr
      Off  : Natural := 0;        --  field byte offset when D_Field
      Ptr_Field : Boolean := False;  --  that field holds a pointer
      Base_On_Stack : Boolean := False;  --  the chain pushed its own base
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
      Implied_Deref : Boolean := False;
      Nested : Natural := 0;
   begin
      if O2c_BC.Bytecode_Mode and then UTypes (UT).Is_Ptr then
         --  A pointer's value is what it designates, and a bare pointer is a
         --  value in its own right (p = q, p := q), so push it once here.  A
         --  field access then needs only its offset: the base is already on
         --  the stack, and is the record's address rather than the pointer
         --  variable's - which is why the scalar leaf below must not push an
         --  address for a pointer base.
         Bc_Load (Base_Name);
      end if;
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
         if Implied_Deref and then Cur.Kind = Lex.Tok_Caret then
            --  The field just loaded the pointer it holds, so this '^' is
            --  implied and the view is the record already.
            Next;
            Implied_Deref := False;
         end if;
         if Cur.Kind = Lex.Tok_Dot and then VK = V_Ptr then
            --  Oberon's implicit dereference: p.f means p^.f.  There is
            --  nothing to emit, because a pointer's value *is* the address
            --  of what it designates, so this only moves the static view -
            --  exactly what the '^' branch does, minus the token.
            VK := V_Rec;
            if UTypes (UT).Ptr_Tgt = 0 and then UTypes (UT).Imported then
               raise O2c_Error with "this POINTER is opaque: dereference "
                 & "only inside its defining module (M26)";
            end if;
            if UTypes (UT).Ptr_Tgt = 0 then
               raise O2c_Error with "internal: deref of an unresolved "
                 & "POINTER TO (line " & Natural'Image (Cur.Line) & ")";
            end if;
            UT := UTypes (UT).Ptr_Tgt;
         end if;
         if Cur.Kind = Lex.Tok_Caret then
            if VK /= V_Ptr then
               raise O2c_Error with "'^' needs a POINTER operand (line "
                 & Natural'Image (Cur.Line) & ")";
            end if;
            Next;
            VK := V_Rec;
            if UTypes (UT).Ptr_Tgt = 0
              and then UTypes (UT).Imported
            then
               raise O2c_Error with "this POINTER is opaque: dereference "
                 & "only inside its defining module (M26)";
            end if;
            UT := UTypes (UT).Ptr_Tgt;
            if UT = 0 then
               raise O2c_Error with "internal: deref of an unresolved "
                 & "POINTER TO (line " & Natural'Image (Cur.Line) & ")";
            end if;
         elsif Cur.Kind = Lex.Tok_LParen then
            --  v(T): a type guard, Oberon's way of narrowing a pointer to a type
            --  it may not have.  Unlike WITH, which skips its body when the guard
            --  fails, this *traps* - GUARD's kind 2 - because there is no body to
            --  skip and the value would otherwise be used as a type it is not.
            if VK /= V_Ptr or else D.Text /= To_Unbounded_String (Base_Name) then
               raise O2c_Error with "'(' is a type guard and needs a POINTER "
                 & "designated by the variable itself (line "
                 & Natural'Image (Cur.Line) & ")";
            end if;
            Next;
            Expect (Lex.Tok_Ident, "a record type in the type guard");
            declare
               GT : constant Natural := Find_UT (Cur.Text (1 .. Cur.Len));
               Trc : constant Natural := UTypes (UT).Ptr_Tgt;
            begin
               if GT = 0 or else not UTypes (GT).Is_Rec
                 or else not Rec_Descends (GT, Trc)
               then
                  raise O2c_Error with "'" & Cur.Text (1 .. Cur.Len)
                    & "' is not an extension of the POINTER's record type "
                    & To_String (UTypes (Trc).Name) & " (line "
                    & Natural'Image (Cur.Line) & ")";
               end if;
               if O2c_BC.Bytecode_Mode then
                  O2c_BC.Guard (Desc_For (GT));
               end if;
               --  past the type name; without this the RParen check saw it
               Next;
               Expect (Lex.Tok_RParen, "')' closing the type guard");
               Next;
               D.Text := To_Unbounded_String
                 (To_String (UTypes (GT).Name) & " ("
                  & To_String (D.Text) & ".all)");
               UT := GT;
               VK := V_Rec;
            end;
         elsif Cur.Kind = Lex.Tok_Dot then
            if VK /= V_Rec then
               if VK = V_Ptr then
                  --  A deliberate deviation: Oberon and Oberon-2 both read
                  --  p.f as p^.f - "the dot implies dereferencing" - while
                  --  this dialect requires the explicit '^'.  The diagnostic
                  --  says what to write rather than implying a language rule.
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
               if UTypes (FO).Imported and then not UTypes (FO).F (F).ExpF
               then
                  --  M22: field-level export marks gate importer access
                  raise O2c_Error with "field '" & Cur.Text (1 .. Cur.Len)
                    & "' of " & To_String (UTypes (FO).Name)
                    & " is not exported";
               end if;
               D.Text := D.Text & "."
                 & Ada_Id (To_String (UTypes (FO).F (F).Name));
               if UTypes (FO).F (F).UT = 0
                 or else (UTypes (FO).F (F).UT = FO
                          --  A field naming the record it sits in, and one
                          --  that nothing selects from, is a terminal leaf
                          --  holding a pointer.  Peek because Cur is still
                          --  the field name here: the selector has not been
                          --  read yet, so Cur cannot answer this.
                          and then Lex.Peek_Token.Kind /= Lex.Tok_Dot
                          and then Lex.Peek_Token.Kind /= Lex.Tok_Caret
                          and then Lex.Peek_Token.Kind /= Lex.Tok_LBracket)
               then
                  D.Sc := UTypes (FO).F (F).Typ;
                  D.Ptr_Field := UTypes (FO).F (F).UT = FO;
                  if D.Ptr_Field then
                     --  A field that names its own record is a pointer, so
                     --  it types as one: assignment stores a pointer and
                     --  equality compares two addresses.  Its user type is
                     --  the record's, since no pointer type names it.
                     D.Sc := T_Ptr;
                     D.UT := UTypes (FO).F (F).UT;
                  end if;
                  if O2c_BC.Bytecode_Mode then
                     --  A record is a run of scalar slots and the descriptor
                     --  fixes each field's offset, so a field needs no bound
                     --  check - what makes that safe is that the emitter can
                     --  only name an offset the descriptor defined.  Only a
                     --  whole record variable for now: a chain of records
                     --  would need the offsets composed, and an extension's
                     --  layout is shared with its parent.
                     if D.Ptr_Field then
                        null;      --  a pointer field is an 8-byte word
                     elsif not (D.Sc = T_Int or else D.Sc = T_Char
                              or else D.Sc = T_Bool
                              or else D.Sc = T_Set
                              or else D.Sc = T_Real
                              or else D.Sc = T_LReal)
                     then
                        --  Reachability of the owning record is Field_Offset's
                        --  business: it raises, with a message naming the
                        --  problem, when the owner is not on the chain.  A
                        --  nested record's field is reached through one, so
                        --  testing the owner against the variable's type here
                        --  would refuse valid accesses.
                        raise O2c_BC.Wrong_Construct with "bytecode backend: "
                            & "only INTEGER, CHAR, BOOLEAN, SET, REAL and "
                            & "LONGREAL record fields are supported";
                     end if;
                     D.Off := Nested + Field_Offset (UT, FO, F);
                     D.K := D_Field;
                     if not UTypes (Base_UT).Is_Ptr
                       and then not D.Base_On_Stack
                     then
                        O2c_BC.Load_Addr_G
                          (O2c_BC.Global_Array
                             (Base_Name, Total_Slots (Base_UT)));
                     end if;
                  else
                     D.K := D_Scalar;
                  end if;
                  Next;           --  past the field name
                  return D;
               end if;
               if UTypes (FO).F (F).UT = FO then
                  --  An intermediate pointer field: what it holds is the
                  --  next record, so load it and carry on chaining from
                  --  there.  Its type is the record itself, so the walk below
                  --  already reaches the right view.
                  if O2c_BC.Bytecode_Mode then
                     O2c_BC.Load_Fld_P ((F - 1) * 8);
                     D.Base_On_Stack := True;
                  end if;
                  Implied_Deref := True;
               end if;
               if O2c_BC.Bytecode_Mode
                 and then UTypes (FO).F (F).UT /= 0
                 and then UTypes (FO).F (F).UT /= FO
                 and then not UTypes (UTypes (FO).F (F).UT).Is_Ptr
               then
                  --  Walking into a nested record or an array: its storage
                  --  starts at this field's own offset inside the record we
                  --  are leaving, so carry that along for whatever the next
                  --  selector computes from.
                  Nested := Nested
                    + Field_Offset (UT, FO, F);
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
            if O2c_BC.Bytecode_Mode
              and then (UTypes (UT).Elem = T_Int
                        or else UTypes (UT).Elem = T_Char
                        or else UTypes (UT).Elem = T_Bool
                        or else UTypes (UT).Elem = T_Real)
            then
               --  An array is a run of scalar slots: push the address of its
               --  first slot before the index is evaluated, so the stack
               --  reads [base, index] for the access the caller emits.  The
               --  chain cannot emit that access itself - it does not know
               --  whether the caller is reading or assigning.
               --  The variable's whole run, at the slot the chain has
               --  walked to: offsets are byte counts and the run is slots,
               --  and every offset here is a multiple of eight.
               O2c_BC.Load_Addr_G
                 (O2c_BC.Global_Array
                    (Base_Name, Total_Slots (Base_UT))
                  + Nested / 8);
            end if;
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
                  if O2c_BC.Bytecode_Mode then
                     --  A packed CHAR array is 0-based bytes, like every
                     --  other array here, so an element is an ordinary
                     --  indexed access and the caller emits it.  The Ada
                     --  path below is 1-based because an Ada String is, and
                     --  classifying this as a scalar there is correct; here
                     --  it left the operands on the stack with no access at
                     --  all, so Out.Char printed the index.
                     D.Text := D.Text & " (" & To_String (Ix.Text) & ")";
                     declare
                        L_In : constant Natural := New_Bc_Label;
                        L_Up : constant Natural := New_Bc_Label;
                     begin
                        O2c_BC.Dup_Top;
                        O2c_BC.Push_Int (0);
                        O2c_BC.Bin (O2c_BC.Ge);
                        O2c_BC.Jump (O2c_BC.Jnz, L_In);
                        O2c_BC.Trap (0);
                        O2c_BC.Mark (L_In);
                        O2c_BC.Dup_Top;
                        O2c_BC.Push_Int (UTypes (UT).Arr_Len);
                        O2c_BC.Bin (O2c_BC.Lt);
                        O2c_BC.Jump (O2c_BC.Jnz, L_Up);
                        O2c_BC.Trap (0);
                        O2c_BC.Mark (L_Up);
                     end;
                     D.K := D_Index;
                     D.Sc := T_Char;
                     return D;
                  end if;
                  --  char array (Ada String, 1-based)
                  D.Text := D.Text & " (" & To_String (Ix.Text) & " + 1)";
                  D.K := D_Scalar;
                  D.Sc := T_Char;
                  return D;
               else
                  D.Text := D.Text & " (" & To_String (Ix.Text) & ")";
                  if O2c_BC.Bytecode_Mode then
                     --  Check the index before the access: the stack holds
                     --  [base, index] and an address carries no length.  Two
                     --  compares, because the opcodes are signed and an index
                     --  below zero has to fail as well.
                     declare
                        L_In : constant Natural := New_Bc_Label;
                        L_Up : constant Natural := New_Bc_Label;
                        begin
                        O2c_BC.Dup_Top;
                        O2c_BC.Push_Int (0);
                        O2c_BC.Bin (O2c_BC.Ge);
                        O2c_BC.Jump (O2c_BC.Jnz, L_In);
                        O2c_BC.Trap (0);
                        O2c_BC.Mark (L_In);
                        O2c_BC.Dup_Top;
                        O2c_BC.Push_Int (UTypes (UT).Arr_Len);
                        O2c_BC.Bin (O2c_BC.Lt);
                        O2c_BC.Jump (O2c_BC.Jnz, L_Up);
                        O2c_BC.Trap (0);
                        O2c_BC.Mark (L_Up);
                        end;
                     D.K := D_Index;
                  else
                     D.K := D_Scalar;
                  end if;
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
      if VK = V_Arr and then UTypes (UT).Elem = T_Char
        and then D.K /= D_Index
      then
         --  The whole array as a string - but only when no index was
         --  selected.  This used to override unconditionally, so s[2] was
         --  classified as the whole string, the indexed path never ran, and
         --  the base and index were left on the stack with no access op:
         --  Out.Char then printed the *index*.  Unreachable until CHAR
         --  arrays stopped being refused, which is why it went unnoticed.
         --  Push the array's address: the packed bytes ARE the string, and
         --  both consumers - the comparison and Out.String - need the
         --  address on the stack.  Returning the designator without pushing
         --  is why `f := s = t` compared nothing, and why discarding an
         --  address there underflowed: there was never one to discard.
         if O2c_BC.Bytecode_Mode then
            O2c_BC.Load_Addr_G
              (O2c_BC.Global_Array (Base_Name, Total_Slots (Base_UT)));
         end if;
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
         if O2c_BC.Bytecode_Mode then
            O2c_BC.Push_Nil;
         end if;
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
            if O2c_BC.Bytecode_Mode then
               declare
                  Nm  : constant String := Cur.Text (1 .. Cur.Len);
                  Sl  : constant Integer := O2c_BC.Local_Slot (Ada_Id (Nm));
               begin
                  if Syms (Id).Open_Arr and then Sl >= 0 then
                     --  Forwarding an ARRAY OF formal: it already carries
                     --  its address and length in its own two slots.
                     O2c_BC.Load_Local (Natural (Sl));
                     O2c_BC.Load_Local (Natural (Sl) + 1);
                  elsif Syms (Id).Open_Arr then
                     raise O2c_BC.Wrong_Construct with "bytecode backend: "
                       & "forwarding a global ARRAY OF parameter is not yet "
                       & "supported";
                  elsif Sl >= 0 then
                     raise O2c_BC.Wrong_Construct with "bytecode backend: "
                       & "an ARRAY OF actual that is a local array is not yet "
                       & "supported";
                  else
                     --  A fixed array: its address, and a length the
                     --  emitter knows because the declaration fixed it.
                     O2c_BC.Load_Addr_G (O2c_BC.Global (Ada_Id (Nm)));
                     O2c_BC.Push_Int (UTypes (Syms (Id).UT).Arr_Len);
                  end if;
               end;
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
         elsif Formal.Typ = T_LReal and then A.Typ = T_Int then
            A.Text := To_Unbounded_String ("Long_Float ("
                                           & To_String (A.Text) & ")");
         elsif Formal.Typ = T_LReal and then A.Typ = T_Real then
            A.Text := To_Unbounded_String ("Long_Float ("
                                           & To_String (A.Text) & ")");
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
                         & Recv & " in " & Ada_Last (To_String (UTypes (Cand (I)).Name))
                         & "'Class then");
            Append_Body ("         "
                         & Method_Impl_Name (MName, Cand (I)) & " ("
                         & Ada_Last (To_String (UTypes (Cand (I)).Name)) & " (" & Recv
                         & ")"
                         & (if N_A > 0 then ", " & To_String (ArgT) else "")
                         & ");");
         end loop;
         Append_Body ("      else");
         Append_Body ("         "
                      & Method_Impl_Name (MName, BaseB) & " ("
                      & Ada_Last (To_String (UTypes (BaseB).Name)) & " (" & Recv & ")"
                      & (if N_A > 0 then ", " & To_String (ArgT) else "")
                      & ");");
         Append_Body ("      end if;");
      else
         --  static binding
         declare
            RecvA : String := Recv;
         begin
            if Td /= 0 then
               RecvA := Ada_Last (To_String (UTypes (BaseB).Name))
                 & " (" & Recv & ")";
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
            --  A record field standing for its own implicit pointer carries
            --  the record's user type rather than a pointer's, so it matches
            --  when that record is what the target pointer points at.
            if R.Ptr_UT /= 0 and then not UTypes (R.Ptr_UT).Is_Ptr then
               if not UTypes (LHS_UT).Is_Ptr
                 or else UTypes (LHS_UT).Ptr_Tgt /= R.Ptr_UT
               then
                  raise O2c_Error with "pointer type mismatch assigning " & LHS;
               end if;
            --  widening: assign a pointer to an extension into a
            --  pointer to its ancestor (M13)
            elsif not UTypes (LHS_UT).Is_Ptr
              or else not UTypes (R.Ptr_UT).Is_Ptr
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
      if O2c_BC.Bytecode_Mode then
         --  The value is already on the stack: the RHS was parsed by
         --  Parse_Expr and NIL emits PUSH_NIL.  A pointer is one scalar slot,
         --  so a whole variable is an ordinary store - but a designator like
         --  p^.next would intern a global named after the Ada text, so it is
         --  refused instead.
         if (for some Ch of LHS =>
               Ch not in 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_')
         then
            raise O2c_BC.Wrong_Construct with "bytecode backend: assigning "
              & "through a pointer designator is not yet supported";
         end if;
         Bc_Store (LHS);
      elsif Conv then
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
            declare
               Raw : constant String := Cur.Text (1 .. Cur.Len);
               Norm : String (1 .. Raw'Length);
               Has_D : Boolean := False;
               Has_Dot : Boolean := False;
            begin
               for I in Raw'Range loop
                  case Raw (I) is
                     when 'D' | 'd' =>
                        Has_D := True;
                        Norm (I) := 'E';     --  Ada spells it with E
                     when '.' =>
                        Has_Dot := True;
                        Norm (I) := '.';
                     when others =>
                        Norm (I) := Raw (I);
                  end case;
               end loop;
               R.Text := To_Unbounded_String (Norm);
               if Has_D then
                  R.Typ := T_LReal;             --  LONGREAL literal (M47)
               elsif Has_Dot then
                  R.Typ := T_Real;              --  REAL literal (M18)
               else
                  R.Typ := T_Int;
               end if;
               if O2c_BC.Bytecode_Mode then
                  if Has_D or else Has_Dot then
                     --  REAL and LONGREAL share the ops and the slot, so
                     --  both are the same literal here.  Ada's Value wants
                     --  an 'E' exponent, so a 'D' is rewritten.
                     declare
                        T : String := To_String (R.Text);
                     begin
                        for I in T'Range loop
                           if T (I) = 'D' or else T (I) = 'd' then
                              T (I) := 'E';
                           end if;
                        end loop;
                        O2c_BC.Push_Real (Long_Float'Value (T));
                     exception
                        when Constraint_Error =>
                           raise O2c_BC.Wrong_Construct with
                             "bytecode backend: real literal out of range: "
                             & To_String (R.Text);
                     end;
                  else
                     begin
                        O2c_BC.Push_Int (Integer'Value (Raw));
                     exception
                        when Constraint_Error =>
                           raise O2c_BC.Wrong_Construct with
                             "bytecode backend: integer literal out of range: "
                             & Raw;
                     end;
                  end if;
               end if;
            end;
            R.Lit := True;
            if R.Typ = T_Int then
               begin
                  R.Val := Integer'Value (To_String (R.Text));
                  R.Folds := True;
               exception
                  when others =>
                     R.Folds := False;
               end;
            end if;
            Next;
         when Lex.Tok_String =>
            if Cur.Len = 1 then
               --  A one-character literal is a CHAR, not a string.  In this
               --  VM a char is an integer in an 8-byte slot, and every
               --  one-character literal in the corpus is used as a char, so
               --  promoting it to a string would put a pointer where a code
               --  belongs - and cost a pool word for the privilege.
               R.Text := To_Unbounded_String
                 ("'" & Cur.Text (1 .. 1) & "'");
               R.Typ := T_Char;
               R.Lit := True;
               if O2c_BC.Bytecode_Mode then
                  O2c_BC.Push_Char (Character'Pos (Cur.Text (1)));
               end if;
               Next;
            else
               R.Text := To_Unbounded_String
                 (Ada_String_Literal (Cur.Text (1 .. Cur.Len)));
               R.Typ := T_Str;
               if O2c_BC.Bytecode_Mode then
                  --  Cur.Text holds the literal's bytes with no quotes (the
                  --  Ada text is quoted separately by Ada_String_Literal), so
                  --  the whole token is the string.  The pool word holds its
                  --  offset in the CONST payload.
                  O2c_BC.Push_Str (Cur.Text (1 .. Cur.Len));
               end if;
               Next;
            end if;
         when Lex.Tok_True =>
            R.Text := To_Unbounded_String ("True");
            R.Typ := T_Bool;
            if O2c_BC.Bytecode_Mode then
               O2c_BC.Push_Bool (True);
            end if;
            Next;
         when Lex.Tok_False =>
            R.Text := To_Unbounded_String ("False");
            R.Typ := T_Bool;
            if O2c_BC.Bytecode_Mode then
               O2c_BC.Push_Bool (False);
            end if;
            Next;
         when Lex.Tok_Nil =>
            R.Text := To_Unbounded_String ("null");
            R.Typ := T_Nil;
            if O2c_BC.Bytecode_Mode then
               O2c_BC.Push_Nil;
            end if;
            Next;
         when Lex.Tok_LBrace =>
            --  SET literal (M17/M34): { e1, e2, ... } with INTEGER or
            --  CHAR elements and INTEGER-literal ranges a..b (0..31)
            Used_Set := True;
            Next;              --  past '{'
            R.Typ := T_Set;
            declare
               Bit   : Unbounded_String;
               First : Boolean := True;

               --  Bytecode: each element's value is already on the operand
               --  stack (its expression was parsed), so SET_SINGLE turns it
               --  into a set and SET_UNION accumulates.  A range pushes no
               --  value, so it contributes a mask instead.  The flag is
               --  separate from Add's, which drives the Ada text.
               Bc_First : Boolean := True;

               procedure Bc_After_Element is
               begin
                  O2c_BC.Un (O2c_BC.Set_Single);
                  if not Bc_First then
                     O2c_BC.Bin (O2c_BC.Set_Union);
                  end if;
                  Bc_First := False;
               end Bc_After_Element;

               procedure Bc_After_Range (Lo : Integer; Hi : Integer) is
                  use type Interfaces.Unsigned_64;
               begin
                  --  the two endpoint values are on the stack and the mask
                  --  is the set; drop them
                  O2c_BC.Discard;
                  O2c_BC.Discard;
                  O2c_BC.Push_Word
                    (Interfaces.Shift_Left (Interfaces.Unsigned_64 (1), Lo)
                     * (Interfaces.Shift_Left
                          (Interfaces.Unsigned_64 (1), Hi - Lo + 1)
                        - Interfaces.Unsigned_64 (1)));
                  if not Bc_First then
                     O2c_BC.Bin (O2c_BC.Set_Union);
                  end if;
                  Bc_First := False;
               end Bc_After_Range;

               procedure Add (Ix : String) is
               begin
                  if First then
                     First := False;
                  else
                     Bit := Bit & " or ";
                  end if;
                  Bit := Bit
                    & "O2c_Set (Interfaces.Shift_Left "
                    & "(Interfaces.Unsigned_32 (1), " & Ix & "))";
               end Add;
            begin
               loop
                  exit when Cur.Kind = Lex.Tok_RBrace;
                  declare
                     E : Expr_Rec := Parse_Expr;
                  begin
                     if E.Typ = T_Char then
                        Add ("Character'Pos (" & To_String (E.Text) & ")");
                        if O2c_BC.Bytecode_Mode then
                           Bc_After_Element;
                        end if;
                     elsif E.Typ = T_Int then
                        if Cur.Kind = Lex.Tok_Dot then
                           --  range element a .. b (M34); '..' lexes as
                           --  two Tok_Dot, detected here by peeking
                           declare
                              T2 : Lex.Token := Lex.Peek_Token;
                           begin
                              if T2.Kind /= Lex.Tok_Dot then
                                 raise O2c_Error with "a lone '.' in a SET "
                                   & "literal (use '..' for ranges, line "
                                   & Natural'Image (Cur.Line) & ")";
                              end if;
                           end;
                           Next;              --  first '.'
                           Next;              --  second '.'

                           declare
                              F : Expr_Rec := Parse_Expr;
                           begin
                              if F.Typ /= T_Int
                                or else not (E.Lit and then F.Lit)
                              then
                                 raise O2c_Error with "SET range endpoints "
                                   & "must be INTEGER literals (line "
                                   & Natural'Image (Cur.Line) & ")";
                              end if;
                              declare
                                 Lo : constant Integer :=
                                   Integer'Value (To_String (E.Text));
                                 Hi : constant Integer :=
                                   Integer'Value (To_String (F.Text));
                              begin
                                 if Lo < 0 or else Hi > 31 or else Lo > Hi
                                 then
                                    raise O2c_Error with "SET ranges must "
                                      & "lie in 0 .. 31 (line "
                                      & Natural'Image (Cur.Line) & ")";
                                 end if;
                                 for K in Lo .. Hi loop
                                    Add (Integer'Image (K));
                                 end loop;
                                 if O2c_BC.Bytecode_Mode then
                                    Bc_After_Range (Lo, Hi);
                                 end if;
                              end;
                           end;
                        else
                           Add (To_String (E.Text));
                           if O2c_BC.Bytecode_Mode then
                              Bc_After_Element;
                           end if;
                        end if;
                     else
                        raise O2c_Error with "set elements must be INTEGER "
                          & "or CHAR (line " & Natural'Image (Cur.Line)
                          & ")";
                     end if;
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
                 and then R.Typ /= T_Real and then R.Typ /= T_LReal
               then
                  raise O2c_Error with "unary sign needs an INTEGER, "
                    & "LONGINT, REAL or LONGREAL (line "
                    & Natural'Image (Cur.Line) & ")";
               end if;
               R.Text := (if Neg then "-" else "") & "(" & R.Text & ")";
               if Neg and then R.Folds then
                  R.Val := -R.Val;
               end if;
            end;
         when Lex.Tok_Ident =>
            if Eq_No_Case (Cur.Text (1 .. Cur.Len), "THREADS") then
               --  Threads.Start (p) in an expression: the value is the new
               --  thread's handle, so a program can keep it and wait for the
               --  thread later.  Without this a handle could only be guessed,
               --  which makes Join unusable for the thing it is for.
               Next;                          --  past Threads
               Expect (Lex.Tok_Dot, "'.' after Threads");
               Next;
               Expect (Lex.Tok_Ident, "a member name after '.'");
               if Cur.Text (1 .. Cur.Len) = "Id" then
                  --  Threads.Id: this thread's own id, so a program can name
                  --  itself the way a spawn names others.
                  Next;                       --  past Id
                  Expect (Lex.Tok_LParen, "'(' after Threads.Id");
                  Next;
                  Expect (Lex.Tok_RParen, "')' after Threads.Id");
                  Next;
                  if not O2c_BC.Bytecode_Mode then
                     raise O2c_Error with "Threads needs the bytecode "
                       & "backend";
                  end if;
                  O2c_BC.Thread_Id;
                  R.Typ := T_Int;
                  R.Text := Null_Unbounded_String;
                  return R;
               end if;
               if Cur.Text (1 .. Cur.Len) /= "Start" then
                  raise O2c_Error with "Threads.Start and Threads.Id are the "
                    & "Threads calls that yield a value (found '"
                    & Cur.Text (1 .. Cur.Len) & "')";
               end if;
               if not O2c_BC.Bytecode_Mode then
                  raise O2c_Error with "Threads needs the bytecode backend "
                    & "(the Ada backend has no threads)";
               end if;
               Next;                          --  past Start -> '('
               Expect (Lex.Tok_LParen, "'(' after Threads.Start");
               Next;
               Expect (Lex.Tok_Ident, "a procedure or a PROCEDURE-typed "
                       & "variable");
               declare
                  Arg : constant String := Cur.Text (1 .. Cur.Len);
                  AI  : constant Natural := Find (Arg);
               begin
                  Next;                       --  past the argument
                  Expect (Lex.Tok_RParen, "')' after Threads.Start");
                  Next;
                  if AI > 0
                    and then Syms (AI).Kind = S_Proc
                    and then not Syms (AI).Ret
                    and then Syms (AI).Bc_Proc /= 0
                  then
                     O2c_BC.Push_BC_Proc (Syms (AI).Bc_Proc);
                  elsif AI > 0 and then Syms (AI).UT > 0
                    and then UTypes (Syms (AI).UT).Is_Proc
                  then
                     Bc_Load (Arg);
                  else
                     raise O2c_Error with "Threads.Start needs a "
                       & "parameterless procedure or a PROCEDURE-typed "
                       & "variable (found '" & Arg & "')";
                  end if;
                  O2c_BC.Spawn;
               end;
               R.Typ := T_Int;
               R.Text := Null_Unbounded_String;
               --  Return here.  Falling out of this branch would drop into the
               --  rest of the arm, which resolves the name as a variable and
               --  then parses another factor - the same fall-through that bit
               --  the statement path, and it fails far from the cause: the
               --  diagnostic names whatever token follows, not Threads.
               return R;
            elsif (To_String (Mod_Name) = "Math"
                or else To_String (Mod_Name) = "MathL")
              and then (Eq_No_Case (Cur.Text (1 .. Cur.Len), "POWER")
                        or else Eq_No_Case (Cur.Text (1 .. Cur.Len), "EXP")
                        or else Eq_No_Case (Cur.Text (1 .. Cur.Len), "LN")
                        or else Eq_No_Case (Cur.Text (1 .. Cur.Len), "LOG")
                        or else Eq_No_Case (Cur.Text (1 .. Cur.Len), "SIN")
                        or else Eq_No_Case (Cur.Text (1 .. Cur.Len), "COS")
                        or else Eq_No_Case (Cur.Text (1 .. Cur.Len), "TAN")
                        or else Eq_No_Case (Cur.Text (1 .. Cur.Len), "ARCSIN")
                        or else Eq_No_Case (Cur.Text (1 .. Cur.Len), "ARCCOS")
                        or else Eq_No_Case (Cur.Text (1 .. Cur.Len), "ARCTAN")
                        or else Eq_No_Case (Cur.Text (1 .. Cur.Len),
                                            "ARCTAN2"))
            then
               --  M41/M47 FFI: REAL/LONGREAL transcendental calls
               declare
                  Nm   : constant String := Cur.Text (1 .. Cur.Len);
                  Pkg  : constant String :=
                    (if To_String (Mod_Name) = "MathL"
                     then "Ada.Numerics.Long_Elementary_Functions."
                     else "Ada.Numerics.Elementary_Functions.");
                  Is_L : constant Boolean :=
                    To_String (Mod_Name) = "MathL";
                  Conv : constant String :=
                    (if Is_L then "Long_Float (" else "Float (");
                  Two  : constant Boolean :=
                    (Eq_No_Case (Nm, "POWER")
                     or else Eq_No_Case (Nm, "LOG")
                     or else Eq_No_Case (Nm, "ARCTAN2"));
                  Ada_Nm : Unbounded_String;
                  A1, A2 : Expr_Rec;
                  procedure Chk (A : Expr_Rec) is
                  begin
                     if Is_L then
                        if A.Typ = T_LReal then
                           null;
                        elsif A.Typ = T_Int and then A.Lit then
                           null;
                        elsif A.Typ = T_Real and then A.Lit then
                           null;
                        else
                           raise O2c_Error with "MathL argument must be "
                             & "LONGREAL";
                        end if;
                     elsif A.Typ /= T_Real
                       and then not (A.Typ = T_Int and then A.Lit)
                     then
                        raise O2c_Error with "Math argument must be REAL";
                     end if;
                  end Chk;
               begin
                  Next;              --  past the reserved name
                  Expect (Lex.Tok_LParen, "'(' after a Math call");
                  Next;
                  A1 := Parse_Expr;
                  Chk (A1);
                  if Two then
                     Expect (Lex.Tok_Comma, "','");
                     Next;
                     A2 := Parse_Expr;
                     Chk (A2);
                  end if;
                  Expect (Lex.Tok_RParen, "')'");
                  Next;
                  if Eq_No_Case (Nm, "POWER") then
                     --  Ada has no real-valued ** : use exp(ex*ln(base))
                     R.Text := To_Unbounded_String (Pkg & "Exp (")
                       & To_String (A2.Text) & " * " & Pkg & "Log ("
                       & To_String (A1.Text) & "))";
                  else
                     if Eq_No_Case (Nm, "LN") or else Eq_No_Case (Nm, "LOG")
                     then
                        Ada_Nm := To_Unbounded_String ("Log");
                     elsif Eq_No_Case (Nm, "ARCTAN2") then
                        Ada_Nm := To_Unbounded_String ("Arctan");
                     else
                        Ada_Nm := To_Unbounded_String (Nm);
                     end if;
                     R.Text := To_Unbounded_String (Pkg) & Ada_Nm & " (";
                  end if;
                  if not Eq_No_Case (Nm, "POWER") then
                     if Eq_No_Case (Nm, "LOG") then
                        --  log(x, base): use named args - positional
                        --  order is X, Base
                        R.Text := R.Text & "Base => " & To_String (A2.Text)
                          & ", X => " & To_String (A1.Text);
                     elsif Two then
                        R.Text := R.Text & To_String (A1.Text) & ", "
                          & To_String (A2.Text);
                     else
                        R.Text := R.Text & To_String (A1.Text);
                     end if;
                     R.Text := R.Text & ")";
                  end if;
                  R.Typ := (if Is_L then T_LReal else T_Real);
               end;
               R.Lit := False;
               return R;
            end if;
            if To_String (Mod_Name) = "Files"
              and then (Eq_No_Case (Cur.Text (1 .. Cur.Len), "FREAD")
                        or else Eq_No_Case (Cur.Text (1 .. Cur.Len),
                                            "FWRITE")
                        or else Eq_No_Case (Cur.Text (1 .. Cur.Len),
                                            "FCLOSE"))
            then
               --  M44 FFI: file I/O with a status result (builtin Files)
               declare
                  Nm   : constant String := Cur.Text (1 .. Cur.Len);
                  Two  : constant Boolean :=
                    not Eq_No_Case (Nm, "FCLOSE");
                  Ada_Nm : constant String :=
                    (if Eq_No_Case (Nm, "FREAD") then "O2c_FRead"
                     elsif Eq_No_Case (Nm, "FWRITE") then "O2c_FWrite"
                     else "O2c_FClose");
                  A1, A2, A3 : Expr_Rec;
               begin
                  Next;
                  Expect (Lex.Tok_LParen, "'(' after the file call");
                  Next;
                  A1 := Parse_Expr;
                  if A1.Typ /= T_Str then
                     raise O2c_Error with "a file path is required";
                  end if;
                  if Two then
                     Expect (Lex.Tok_Comma, "','");
                     Next;
                     A2 := Parse_Expr;
                     if not (A2.Typ = T_Int or else A2.Typ = T_Long) then
                        raise O2c_Error with "the offset must be INTEGER "
                          & "or LONGINT";
                     end if;
                     Expect (Lex.Tok_Comma, "','");
                     Next;
                     A3 := Parse_Expr;
                     if A3.Typ /= T_Str then
                        raise O2c_Error with "an ARRAY OF CHAR buffer is "
                          & "required";
                     end if;
                  end if;
                  Expect (Lex.Tok_RParen, "')'");
                  Next;
                  R.Text := To_Unbounded_String (Ada_Nm & " ("
                                                 & To_String (A1.Text));
                  if Two then
                     R.Text := R.Text & ", " & To_String (A2.Text)
                       & ", " & To_String (A3.Text);
                  end if;
                  R.Text := R.Text & ")";
               end;
               R.Typ := T_Int;
               R.Lit := False;
               return R;
            end if;
            if To_String (Mod_Name) = "Args"
              and then Eq_No_Case (Cur.Text (1 .. Cur.Len), "ARGCOUNT")
            then
               --  M50 FFI: argument count (builtin Args only)
               Next;
               if Cur.Kind = Lex.Tok_LParen then
                  Next;
                  Expect (Lex.Tok_RParen, "')'");
                  Next;
               end if;
               R.Text := To_Unbounded_String ("O2c_Arg_Count");
               R.Typ := T_Int;
               R.Lit := False;
               return R;
            end if;
            if To_String (Mod_Name) = "XYplane"
              and then (Eq_No_Case (Cur.Text (1 .. Cur.Len), "PLANEISDOT")
                        or else Eq_No_Case (Cur.Text (1 .. Cur.Len),
                                            "PLANEKEY"))
            then
               --  M49 FFI: plane query + key (builtin XYplane only)
               declare
                  Is_Dot : constant Boolean :=
                    Eq_No_Case (Cur.Text (1 .. Cur.Len), "PLANEISDOT");
                  A1, A2 : Expr_Rec;
               begin
                  Next;
                  if not Is_Dot and then Cur.Kind /= Lex.Tok_LParen then
                     --  PlaneKey takes no arguments: written bare
                     R.Text := To_Unbounded_String ("O2c_Plane_Key");
                     R.Typ := T_Char;
                     R.Lit := False;
                     return R;
                  end if;
                  Expect (Lex.Tok_LParen, "'(' after the plane call");
                  Next;
                  A1 := Parse_Expr;
                  if A1.Typ /= T_Int then
                     raise O2c_Error with "plane coordinates are INTEGER";
                  end if;
                  if Is_Dot then
                     Expect (Lex.Tok_Comma, "','");
                     Next;
                     A2 := Parse_Expr;
                     if A2.Typ /= T_Int then
                        raise O2c_Error with "plane coordinates are INTEGER";
                     end if;
                  end if;
                  Expect (Lex.Tok_RParen, "')'");
                  Next;
                  if Is_Dot then
                     R.Text := To_Unbounded_String
                       ("O2c_Plane_IsDot (" & To_String (A1.Text) & ", "
                        & To_String (A2.Text) & ")");
                     R.Typ := T_Bool;
                  else
                     R.Text := To_Unbounded_String ("O2c_Plane_Key");
                     R.Typ := T_Char;
                  end if;
               end;
               R.Lit := False;
               return R;
            end if;
            if To_String (Mod_Name) = "Input"
              and then (Eq_No_Case (Cur.Text (1 .. Cur.Len), "INAVAIL")
                        or else Eq_No_Case (Cur.Text (1 .. Cur.Len),
                                            "INREADCH")
                        or else Eq_No_Case (Cur.Text (1 .. Cur.Len),
                                            "INTIME"))
            then
               --  M48 FFI: Input primitives (builtin Input module only)
               declare
                  Nm : constant String := Cur.Text (1 .. Cur.Len);
               begin
                  Next;
                  if Cur.Kind = Lex.Tok_LParen then
                     Next;
                     Expect (Lex.Tok_RParen, "')'");
                     Next;
                  end if;
                  if Eq_No_Case (Nm, "INAVAIL") then
                     R.Text := To_Unbounded_String ("O2c_In_Avail");
                     R.Typ := T_Int;
                  elsif Eq_No_Case (Nm, "INREADCH") then
                     R.Text := To_Unbounded_String ("O2c_In_ReadCh");
                     R.Typ := T_Char;
                  else
                     R.Text := To_Unbounded_String ("O2c_In_Time");
                     R.Typ := T_Long;
                  end if;
               end;
               R.Lit := False;
               return R;
            end if;
            if To_String (Mod_Name) = "In"
              and then (Eq_No_Case (Cur.Text (1 .. Cur.Len), "INCHAR")
                        or else Eq_No_Case (Cur.Text (1 .. Cur.Len),
                                            "ININT")
                        or else Eq_No_Case (Cur.Text (1 .. Cur.Len),
                                            "INLONG")
                        or else Eq_No_Case (Cur.Text (1 .. Cur.Len),
                                            "INREAL"))
            then
               --  M45 FFI: input primitives (builtin In module only)
               declare
                  Nm : constant String := Cur.Text (1 .. Cur.Len);
               begin
                  Next;
                  if Cur.Kind = Lex.Tok_LParen then
                     Next;
                     Expect (Lex.Tok_RParen, "')'");
                     Next;
                  end if;
                  if Eq_No_Case (Nm, "INCHAR") then
                     R.Text := To_Unbounded_String ("O2c_In_Char");
                     R.Typ := T_Char;
                  elsif Eq_No_Case (Nm, "ININT") then
                     R.Text := To_Unbounded_String ("O2c_In_Int");
                     R.Typ := T_Int;
                  elsif Eq_No_Case (Nm, "INLONG") then
                     R.Text := To_Unbounded_String ("O2c_In_Long");
                     R.Typ := T_Long;
                  else
                     R.Text := To_Unbounded_String ("O2c_In_Real");
                     R.Typ := T_Real;
                  end if;
               end;
               R.Lit := False;
               return R;
            end if;
            if To_String (Mod_Name) = "Reals"
              and then Eq_No_Case (Cur.Text (1 .. Cur.Len), "RPARSE")
            then
               --  M46 FFI: string -> REAL (builtin Reals only)
               declare
                  A : Expr_Rec;
               begin
                  Next;
                  Expect (Lex.Tok_LParen, "'(' after RParse");
                  Next;
                  A := Parse_Expr;
                  if A.Typ /= T_Str then
                     raise O2c_Error with "RParse needs an ARRAY OF CHAR";
                  end if;
                  Expect (Lex.Tok_RParen, "')'");
                  Next;
                  R.Text := To_Unbounded_String
                    ("O2c_StrToReal (" & To_String (A.Text) & ")");
               end;
               R.Typ := T_Real;
               R.Lit := False;
               return R;
            end if;
            if To_String (Mod_Name) = "Files"
              and then Eq_No_Case (Cur.Text (1 .. Cur.Len), "FSTAT")
            then
               --  M40 FFI: file size probe (builtin Files module only)
               Next;              --  past FStat
               Expect (Lex.Tok_LParen, "'(' after FStat");
               Next;
               declare
                  A : Expr_Rec := Parse_Expr;
               begin
                  if A.Typ /= T_Str then
                     raise O2c_Error with "FStat needs a file path";
                  end if;
                  Expect (Lex.Tok_RParen, "')'");
                  Next;
                  R.Text := To_Unbounded_String
                    ("O2c_FStat (" & To_String (A.Text) & ")");
               end;
               R.Typ := T_Long;
               R.Lit := False;
               return R;
            end if;
            if Eq_No_Case (Cur.Text (1 .. Cur.Len), "ORD")
              or else Eq_No_Case (Cur.Text (1 .. Cur.Len), "CHR")
              or else Eq_No_Case (Cur.Text (1 .. Cur.Len), "ABS")
              or else Eq_No_Case (Cur.Text (1 .. Cur.Len), "ODD")
            then
               --  predeclared functions (M25): ORD/CHR/ABS/ODD
               declare
                  Fn : constant String := Cur.Text (1 .. Cur.Len);
               begin
                  Next;             --  past the function name
                  Expect (Lex.Tok_LParen, "'(' after " & Fn);
                  Next;
                  declare
                     A : Expr_Rec := Parse_Expr;
                  begin
                     if Eq_No_Case (Fn, "ORD") then
                        if A.Typ /= T_Char then
                           raise O2c_Error with "ORD needs a CHAR argument";
                        end if;
                        R.Text := To_Unbounded_String
                          ("Character'Pos (" & To_String (A.Text) & ")");
                        R.Typ := T_Int;
                     elsif Eq_No_Case (Fn, "CHR") then
                        if A.Typ /= T_Int then
                           raise O2c_Error with "CHR needs an INTEGER "
                             & "argument";
                        end if;
                        R.Text := To_Unbounded_String
                          ("Character'Val (" & To_String (A.Text) & ")");
                        R.Typ := T_Char;
                     elsif Eq_No_Case (Fn, "ABS") then
                        if not (A.Typ = T_Int or else A.Typ = T_Long
                                or else A.Typ = T_Real)
                        then
                           raise O2c_Error with "ABS needs an INTEGER, "
                             & "LONGINT or REAL argument";
                        end if;
                        R.Text := To_Unbounded_String
                          ("abs (" & To_String (A.Text) & ")");
                        R.Typ := A.Typ;
                     else  --  ODD
                        if A.Typ /= T_Int and then A.Typ /= T_Long then
                           raise O2c_Error with "ODD needs an INTEGER or "
                             & "LONGINT argument";
                        end if;
                        R.Text := To_Unbounded_String
                          ("((" & To_String (A.Text) & " mod 2) = 1)");
                        R.Typ := T_Bool;
                     end if;
                  end;
                  Expect (Lex.Tok_RParen, "')'");
                  Next;
               end;
               return R;
            end if;
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
                           if Xs (XI).Kind = S_Const then
                              R.Text := To_Unbounded_String
                                (Ada_Id (FNm) & "." & Ada_Id (MName));
                              R.Typ := Xs (XI).Typ;
                              R.Lit := False;
                              return R;
                           end if;
                           if Xs (XI).Kind = S_Var
                             and then Length (Xs (XI).VT_Nm) = 0
                           then
                              R.Text := To_Unbounded_String
                                (Ada_Id (FNm) & "." & Ada_Id (MName));
                              R.Typ := Xs (XI).Typ;
                              R.Lit := False;
                              return R;
                           end if;
                           if Xs (XI).Kind = S_Var then
                              --  M20f: exported RECORD VARIABLE: reach a
                              --  field through the designator chain
                              declare
                                 Q : constant String :=
                                   To_String (Xs (XI).VT_Nm);
                                 U : constant Natural :=
                                   Import_Type (Q_Owner (Q), Q_Mem (Q));
                              begin
                                 if Cur.Kind /= Lex.Tok_Dot then
                                    raise O2c_Error with "'" & FNm & "."
                                      & MName
                                      & "' is a RECORD VARIABLE; select a "
                                      & "field with '.'";
                                 end if;
                                 declare
                                    D : Desig := Parse_Rec_Ptr_Chain
                                      (Ada_Id (FNm) & "." & Ada_Id (MName), U);
                                 begin
                                    if D.K = D_Index then
                                       --  [base, index]: load the element.
                                       R.Typ := D.Sc;
                                       if D.Sc = T_Char or else D.Sc = T_Bool then
                                          O2c_BC.Bin (O2c_BC.Load_Idx_B);
                                       else
                                          O2c_BC.Bin (O2c_BC.Load_Idx_I);
                                       end if;
                                    elsif D.K = D_Field then
                                       --  [record]: the field at a known offset.
                                       R.Typ := D.Sc;
                                       if D.Ptr_Field then O2c_BC.Load_Fld_P (D.Off);
                                        elsif D.Sc = T_Real or else D.Sc = T_LReal then
                                           O2c_BC.Load_Fld_R (D.Off);
                                        else O2c_BC.Load_Fld (D.Off);
                                        end if;
                                    elsif D.K = D_Scalar then
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
                                 Call := Call & Ada_Id (FNm) & "."
                             & Ada_Id (MName) & " (";
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
                                (Ada_Id (FNm) & "." & Ada_Id (MName));
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
                     if O2c_BC.Bytecode_Mode then
                        --  The arguments are already on the stack, pushed by
                        --  Parse_Actual; this is the call itself.  It was
                        --  never emitted on the expression path, so f(x)
                        --  pushed x and silently took it as the result -
                        --  Twice(21) was 21.  A function call as a statement
                        --  went through the other path, which had it.
                        if Syms (Id).Foreign_Native /= 0 then
                           --  A foreign procedure has no Oberon code: its
                           --  body is the C function, reached by
                           --  CALL_NATIVE.  The arity comes from the
                           --  declaration and the verifier checks it against
                           --  the VM's table, so a stub that disagrees fails
                           --  at load rather than unbalancing the stack.
                           O2c_BC.Native_Call (Syms (Id).Foreign_Native,
                                               Syms (Id).Params);
                        else
                           if Syms (Id).Bc_Proc = 0 then
                              raise O2c_Error with "bytecode backend: call "
                                & "to '" & Cur.Text (1 .. Cur.Len)
                                & "' with no procedure id";
                           end if;
                           O2c_BC.Call_Proc (Syms (Id).Bc_Proc);
                        end if;
                     end if;
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
                        if O2c_BC.Bytecode_Mode then
                           --  p IS T asks the object's dynamic type, or an
                           --  extension of it.  A pointer is the object's
                           --  address, so the value itself is the operand.
                           Bc_Load (Nm);
                           O2c_BC.Type_Test (Desc_For (TT));
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
                                    if O2c_BC.Bytecode_Mode then
                                       --  A receiver is self: a pointer's
                                       --  value is the object's address, and
                                       --  a VAR record's address is too.  The
                                       --  arguments follow, pushed by
                                       --  Parse_Actual, and then the dispatch.
                                       if UTypes (U).Is_Ptr then
                                          Bc_Load (Nm);
                                       else
                                          --  A VAR record receiver would be
                                          --  a global, and only ALLOC_NEW
                                          --  objects carry a type tag, so
                                          --  there is nothing to dispatch
                                          --  on.  A pointer receiver is the
                                          --  form that works, and the one
                                          --  the samples use.
                                          raise O2c_BC.Wrong_Construct with
                                            "bytecode backend: a method on "
                                            & "a VAR record receiver is not "
                                            & "supported; use a POINTER "
                                            & "receiver";
                                       end if;
                                    end if;
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
                                    if O2c_BC.Bytecode_Mode then
                                       --  The index of the method in the
                                       --  receiver type's table: the same
                                       --  name, inherited or overridden, so
                                       --  the same slot whichever type the
                                       --  object turns out to be.
                                       declare
                                          MIdx : Natural := 0;
                                       begin
                                          Fill_Table (Urec);
                                          for I in 1 .. Mtabs (Urec).N loop
                                             if To_String (Mtabs (Urec).M (I).Name)
                                               = DN
                                             then
                                                MIdx := I - 1;
                                             end if;
                                          end loop;
                                          O2c_BC.Dispatch (MIdx, Exp, 1);
                                       end;
                                    end if;
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
                              if BI = 0 and then
                                XM_Chain (Urec, Mb (1 .. M_Len)) /= 0
                              then
                                 --  M20d/M23: method function from an
                                 --  imported record (or a local extension
                                 --  of one): call the exported dispatcher
                                 --  and use its result.
                                 declare
                                    XMI  : constant Natural :=
                                      XM_Chain (Urec, Mb (1 .. M_Len));
                                    Ownr : constant String :=
                                      To_String (XMs (XMI).Owner);
                                 begin
                                    if XMI /= 0 then
                                       if not XMs (XMI).Ret then
                                          raise O2c_Error with "method '"
                                            & Mb (1 .. M_Len)
                                            & "' is a proper procedure, not "
                                            & "a function (line "
                                            & Natural'Image (Cur.Line) & ")";
                                       end if;
                                       declare
                                          RNm : constant String :=
                                            To_String (XMs (XMI).RecN);
                                          Rcv : constant String :=
                                            (if UTypes (U).Is_Ptr
                                             then Nm & ".all"
                                             else Nm);
                                          Call : Unbounded_String;
                                          N_A  : Natural := 0;
                                       begin
                                          Next;   --  past '.'
                                          Expect (Lex.Tok_Ident,
                                                  "a method name");
                                          Next;   --  past method name
                                          Expect (Lex.Tok_LParen, "'('");
                                          Next;
                                          declare
                                             SI : constant Natural :=
                                               Sh_Find (Ownr, RNm,
                                                        Mb (1 .. M_Len));
                                          begin
                                             if SI /= 0 then
                                                --  M29/M30: widened-pointer
                                                --  dispatch (function)
                                                Call := Call
                                                  & To_String (Shs (SI).Owner)
                                                  & "." & Mb (1 .. M_Len)
                                                  & "_Any_Disp_O2c_"
                                                  & To_String (Shs (SI).BRec)
                                                  & " (" & Rcv;
                                             else
                                                Call := Call & Ownr & "."
                                                  & Mb (1 .. M_Len)
                                                  & "_Disp_O2c_" & RNm
                                                  & " (" & Rcv;
                                             end if;
                                          end;
                                          loop
                                             exit when
                                               Cur.Kind = Lex.Tok_RParen;
                                             N_A := N_A + 1;
                                             if N_A > XMs (XMI).Params then
                                                raise O2c_Error with
                                                  "method '" & Mb (1 .. M_Len)
                                                  & "' expects "
                                                  & Natural'Image
                                                    (XMs (XMI).Params)
                                                  & " argument(s)";
                                             end if;
                                             declare
                                                A : Expr_Rec := Parse_Actual
                                                  (XM_Formal (XMI, N_A));
                                             begin
                                                Call := Call & ", "
                                                  & To_String (A.Text);
                                             end;
                                             exit when
                                               Cur.Kind /= Lex.Tok_Comma;
                                             Next;
                                          end loop;
                                          if N_A /= XMs (XMI).Params then
                                             raise O2c_Error with
                                               "method '" & Mb (1 .. M_Len)
                                               & "' expects "
                                               & Natural'Image
                                                 (XMs (XMI).Params)
                                               & " argument(s), got "
                                               & Natural'Image (N_A);
                                          end if;
                                          Expect (Lex.Tok_RParen, "')'");
                                          Next;
                                          Call := Call & ")";
                                          R.Text := Call;
                                          if Length (XMs (XMI).Ret_Nm) > 0
                                          then
                                             declare
                                                Q : constant String :=
                                                  To_String
                                                    (XMs (XMI).Ret_Nm);
                                             begin
                                                R.Typ := T_Ptr;
                                                R.Ptr_UT := Import_Type
                                                  (Q_Owner (Q), Q_Mem (Q));
                                             end;
                                          else
                                             R.Typ := XMs (XMI).Typ;
                                          end if;
                                          return R;
                                       end;
                                    end if;
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
                     if D.K = D_Index then
                        --  [base, index]: load the element.
                        R.Typ := D.Sc;
                        if D.Sc = T_Char or else D.Sc = T_Bool then
                           O2c_BC.Bin (O2c_BC.Load_Idx_B);
                        else
                           O2c_BC.Bin (O2c_BC.Load_Idx_I);
                        end if;
                     elsif D.K = D_Field then
                        --  [record]: the field at a known offset.
                        R.Typ := D.Sc;
                        if D.Ptr_Field then
                           R.Ptr_UT := D.UT;
                           O2c_BC.Load_Fld_P (D.Off);
                         elsif D.Sc = T_Real or else D.Sc = T_LReal then
                            O2c_BC.Load_Fld_R (D.Off);
                         else O2c_BC.Load_Fld (D.Off);
                         end if;
                     elsif D.K = D_Scalar then
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
                  if O2c_BC.Bytecode_Mode then
                     --  An open array's address is in the parameter's own
                     --  slot, not in a global run, so the base is a local
                     --  load rather than a global address.
                     O2c_BC.Load_Local
                       (Natural (O2c_BC.Local_Slot (Ada_Id (Nm))));
                  end if;
                  declare
                     Ix : Expr_Rec := Parse_Expr;
                  begin
                     if Ix.Typ /= T_Int then
                        raise O2c_Error with "array index must be INTEGER";
                     end if;
                     if O2c_BC.Bytecode_Mode then
                        --  Bound against the length that travelled with the
                        --  array.  A fixed array's bound is a constant the
                        --  emitter knows; an open one's is a runtime value,
                        --  which is why the spec calls LOAD_IDX bounds
                        --  checked rather than leaving it to the caller.
                        declare
                           L_Ok : constant Natural := New_Bc_Label;
                           L_In : constant Natural := New_Bc_Label;
                           Len  : constant Natural :=
                             Natural (O2c_BC.Local_Slot (Ada_Id (Nm))) + 1;
                        begin
                           O2c_BC.Dup_Top;
                           O2c_BC.Push_Int (0);
                           O2c_BC.Bin (O2c_BC.Ge);
                           O2c_BC.Jump (O2c_BC.Jnz, L_In);
                           O2c_BC.Trap (0);
                           O2c_BC.Mark (L_In);
                           O2c_BC.Dup_Top;
                           O2c_BC.Load_Local (Len);
                           O2c_BC.Bin (O2c_BC.Lt);
                           O2c_BC.Jump (O2c_BC.Jnz, L_Ok);
                           O2c_BC.Trap (0);
                           O2c_BC.Mark (L_Ok);
                           --  An open array's element type comes from the
                           --  parameter, not from a designator.
                           if Syms (Id).Typ = T_Char then
                              O2c_BC.Bin (O2c_BC.Load_Idx_B);
                           else
                              O2c_BC.Bin (O2c_BC.Load_Idx_I);
                           end if;
                        end;
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
               if O2c_BC.Bytecode_Mode then
                  if Syms (Id).Kind = S_Const then
                     --  A constant has no storage to load: its value is the
                     --  value.  Only a plain literal can be pushed, so a
                     --  computed constant is refused here rather than becoming
                     --  a zero.
                     if not Syms (Id).Const_Usable then
                        --  A constant is not storage: the bytecode backend
                        --  has no slot to load it from, so it needs the value
                        --  itself.  This is reached when the value could not
                        --  be folded - a REAL or SET expression, or an
                        --  integer one that overflowed or divided by zero.
                        raise O2c_BC.Wrong_Construct with "bytecode backend: '"
                          & Cur.Text (1 .. Cur.Len)
                          & "' is not a constant INTEGER expression, so its "
                          & "value cannot be pushed";
                     end if;
                     O2c_BC.Push_Int (Syms (Id).Const_Val);
                     R.Typ := Syms (Id).Typ;
                     R.Text := Null_Unbounded_String;
                     R.Lit := True;
                     R.Val := Syms (Id).Const_Val;
                     R.Folds := Syms (Id).Const_Usable
                       and then Syms (Id).Typ = T_Int;
                     --  Consume the name before returning.  The shared Next
                     --  further down belongs to the path that falls through,
                     --  so leaving early without this leaves the parser
                     --  sitting on the identifier - which surfaces as
                     --  "expected ..." errors far from the constant.
                     Next;
                     return R;
                  elsif Syms (Id).Kind /= S_Var then
                     raise O2c_BC.Wrong_Construct with "bytecode backend: '"
                       & Cur.Text (1 .. Cur.Len)
                       & "' is not a module variable";
                  elsif Syms (Id).UT /= 0 or else Syms (Id).Open_Arr then
                     raise O2c_BC.Wrong_Construct with "bytecode backend: "
                       & "pointers and arrays are not yet supported";
                  elsif Syms (Id).Typ /= T_Int
                    and then Syms (Id).Typ /= T_Char
                    and then Syms (Id).Typ /= T_Bool
                  and then Syms (Id).Typ /= T_Set
                  and then Syms (Id).Typ /= T_Real
                  and then Syms (Id).Typ /= T_LReal
                  and then Syms (Id).Typ /= T_Long
                  then
                     raise O2c_BC.Wrong_Construct with "bytecode backend: "
                       & "only INTEGER/CHAR/BOOLEAN variables are supported";
                  end if;
                  Bc_Load (Ada_Id (Cur.Text (1 .. Cur.Len)));
               end if;
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

   --  Fold a binary operation on two INTEGER constants, as the expression
   --  is parsed.  Anything that does not fold clears Folds, and a constant
   --  declaration then refuses the name rather than reading a zero.
   procedure Fold_Bin (R : in out Expr_Rec; X : Expr_Rec; Op : Character) is
   begin
      if not (R.Folds and then X.Folds) then
         R.Folds := False;
         return;
      end if;
      begin
         case Op is
            when '+' => R.Val := R.Val + X.Val;
            when '-' => R.Val := R.Val - X.Val;
            when '*' => R.Val := R.Val * X.Val;
            when '/' => R.Val := R.Val / X.Val;
            when 'm' => R.Val := R.Val rem X.Val;
            when others => R.Folds := False;
         end case;
      exception
         when others =>
            --  Division by zero, or an overflow: not a constant.
            R.Folds := False;
      end;
   end Fold_Bin;

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
      --  M47: LONGREAL mixes with literals and with the other real kind
      --  only when that side is a plain literal (documented deviation).
      if A.Typ = T_LReal and then B.Typ = T_LReal then
         Res := T_LReal;
         return True;
      elsif A.Typ = T_LReal
        and then (B.Typ = T_Int or else B.Typ = T_Real) and then B.Lit
      then
         Res := T_LReal;
         return True;
      elsif (A.Typ = T_Int or else A.Typ = T_Real) and then A.Lit
        and then B.Typ = T_LReal
      then
         Res := T_LReal;
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
                  if O2c_BC.Bytecode_Mode then
                     O2c_BC.Bin (O2c_BC.Set_Intersect);
                     --  The operands are already on the stack.
                  end if;
                  R.Text := "(" & R.Text & " and " & X.Text & ")";
                  R.Lit := False;
               elsif Int_Like (R, X, Res) then
                  R.Text := R.Text & " * " & X.Text;
                  R.Typ := Res;
                  R.Lit := False;
                  Fold_Bin (R, X, '*');
                  if O2c_BC.Bytecode_Mode then
                     if Res = T_Long then
                        raise O2c_BC.Wrong_Construct with "bytecode backend: "
                          & "LONGINT is not yet supported";
                     elsif Res = T_Int then
                        O2c_BC.Bin (O2c_BC.Mul);
                     elsif R.Typ /= T_Int and then X.Typ /= T_Int then
                        --  REAL and LONGREAL share the ops; both operands must be
                        --  non-integer, or an implicit I2R would be needed and the wrong
                        --  opcode would be silent.
                        O2c_BC.Bin (O2c_BC.Rmul);
                     else
                        raise O2c_BC.Wrong_Construct with "bytecode backend: "
                          & "a mixed INTEGER/REAL operation is not yet supported";
                     end if;
                  end if;
               elsif Real_Like (R, X, Res) then
                  declare
                     Conv : constant String :=
                       (if Res = T_LReal then "Long_Float (" else "Float (");
                  begin
                     if R.Typ = T_Int
                       or else (R.Typ = T_Real and then Res = T_LReal)
                     then
                        R.Text := To_Unbounded_String
                          (Conv & To_String (R.Text) & ")");
                     elsif X.Typ = T_Int
                       or else (X.Typ = T_Real and then Res = T_LReal)
                     then
                        X.Text := To_Unbounded_String
                          (Conv & To_String (X.Text) & ")");
                     end if;
                  end;
                  --  Both operands are real-valued here; a coerced
                  --  integer would need an I2R first and is refused.
                  if O2c_BC.Bytecode_Mode then
                     if R.Typ = T_Int or else X.Typ = T_Int then
                        raise O2c_BC.Wrong_Construct with "bytecode backend: "
                          & "a mixed INTEGER/REAL operation is not yet "
                          & "supported";
                     end if;
                     O2c_BC.Bin (O2c_BC.Rmul);
                  end if;
                  R.Text := R.Text & " * " & X.Text;
                  R.Typ := Res;
                  R.Lit := False;
                  Fold_Bin (R, X, '*');
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
               Fold_Bin (R, X, '/');
               if O2c_BC.Bytecode_Mode then
                  if Res = T_Long then
                     raise O2c_BC.Wrong_Construct with "bytecode backend: "
                       & "LONGINT is not yet supported";
                  elsif Res = T_Int then
                     O2c_BC.Bin (O2c_BC.IDiv);
                  elsif R.Typ /= T_Int and then X.Typ /= T_Int then
                     --  REAL and LONGREAL share the ops; both operands must be
                     --  non-integer, or an implicit I2R would be needed and the wrong
                     --  opcode would be silent.
                     O2c_BC.Bin (O2c_BC.Rdiv);
                  else
                     raise O2c_BC.Wrong_Construct with "bytecode backend: "
                       & "a mixed INTEGER/REAL operation is not yet supported";
                  end if;
               end if;
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
               Fold_Bin (R, X, 'm');
               if O2c_BC.Bytecode_Mode then
                  if Res /= T_Int then
                     raise O2c_BC.Wrong_Construct with "bytecode backend: "
                       & "MOD needs INTEGER operands";
                  end if;
                  O2c_BC.Bin (O2c_BC.IMod);
               end if;
            end;
         elsif Cur.Kind = Lex.Tok_Slash then
            --  '/' is REAL division, or SET symmetric difference
            Next;
            declare
               X : Expr_Rec := Parse_Factor;
               Res : EType;
            begin
               if R.Typ = T_Set and then X.Typ = T_Set then
                  if O2c_BC.Bytecode_Mode then
                     O2c_BC.Bin (O2c_BC.Set_Symdiff);
                     --  The operands are already on the stack.
                  end if;
                  R.Text := "(" & R.Text & " xor " & X.Text & ")";
                  R.Lit := False;
               elsif Real_Like (R, X, Res) then
                  declare
                     Conv : constant String :=
                       (if Res = T_LReal then "Long_Float (" else "Float (");
                  begin
                     if R.Typ = T_Int
                       or else (R.Typ = T_Real and then Res = T_LReal)
                     then
                        R.Text := To_Unbounded_String
                          (Conv & To_String (R.Text) & ")");
                     elsif X.Typ = T_Int
                       or else (X.Typ = T_Real and then Res = T_LReal)
                     then
                        X.Text := To_Unbounded_String
                          (Conv & To_String (X.Text) & ")");
                     end if;
                  end;
                  --  Both operands are real-valued here; a coerced
                  --  integer would need an I2R first and is refused.
                  if O2c_BC.Bytecode_Mode then
                     if R.Typ = T_Int or else X.Typ = T_Int then
                        raise O2c_BC.Wrong_Construct with "bytecode backend: "
                          & "a mixed INTEGER/REAL operation is not yet "
                          & "supported";
                     end if;
                     O2c_BC.Bin (O2c_BC.Rdiv);
                  end if;
                  R.Text := R.Text & " / " & X.Text;
                  R.Typ := Res;
                  R.Lit := False;
                  Fold_Bin (R, X, '/');
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
               if O2c_BC.Bytecode_Mode then
                  raise O2c_BC.Wrong_Construct with
                    "bytecode backend: '&' is not yet supported";
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
                  if O2c_BC.Bytecode_Mode then
                     O2c_BC.Bin (O2c_BC.Set_Union);
                     --  The operands are already on the stack.
                  end if;
                  R.Text := "(" & R.Text & " or " & X.Text & ")";
                  R.Lit := False;
               elsif Int_Like (R, X, Res) then
                  R.Text := R.Text & " + " & X.Text;
                  R.Typ := Res;
                  R.Lit := False;
                  Fold_Bin (R, X, '+');
                  if O2c_BC.Bytecode_Mode then
                     if Res = T_Long then
                        raise O2c_BC.Wrong_Construct with "bytecode backend: "
                          & "LONGINT is not yet supported";
                     elsif Res = T_Int then
                        O2c_BC.Bin (O2c_BC.Add);
                     elsif R.Typ /= T_Int and then X.Typ /= T_Int then
                        --  REAL and LONGREAL share the ops; both operands must be
                        --  non-integer, or an implicit I2R would be needed and the wrong
                        --  opcode would be silent.
                        O2c_BC.Bin (O2c_BC.Radd);
                     else
                        raise O2c_BC.Wrong_Construct with "bytecode backend: "
                          & "a mixed INTEGER/REAL operation is not yet supported";
                     end if;
                  end if;
               elsif Real_Like (R, X, Res) then
                  declare
                     Conv : constant String :=
                       (if Res = T_LReal then "Long_Float (" else "Float (");
                  begin
                     if R.Typ = T_Int
                       or else (R.Typ = T_Real and then Res = T_LReal)
                     then
                        R.Text := To_Unbounded_String
                          (Conv & To_String (R.Text) & ")");
                     elsif X.Typ = T_Int
                       or else (X.Typ = T_Real and then Res = T_LReal)
                     then
                        X.Text := To_Unbounded_String
                          (Conv & To_String (X.Text) & ")");
                     end if;
                  end;
                  --  Both operands are real-valued here; a coerced
                  --  integer would need an I2R first and is refused.
                  if O2c_BC.Bytecode_Mode then
                     if R.Typ = T_Int or else X.Typ = T_Int then
                        raise O2c_BC.Wrong_Construct with "bytecode backend: "
                          & "a mixed INTEGER/REAL operation is not yet "
                          & "supported";
                     end if;
                     O2c_BC.Bin (O2c_BC.Radd);
                  end if;
                  R.Text := R.Text & " + " & X.Text;
                  R.Typ := Res;
                  R.Lit := False;
                  Fold_Bin (R, X, '+');
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
                  if O2c_BC.Bytecode_Mode then
                     O2c_BC.Bin (O2c_BC.Set_Diff);
                     --  The operands are already on the stack.
                  end if;
                  R.Text := "(" & R.Text & " and not " & X.Text & ")";
                  R.Lit := False;
               elsif Int_Like (R, X, Res) then
                  R.Text := R.Text & " - " & X.Text;
                  R.Typ := Res;
                  R.Lit := False;
                  Fold_Bin (R, X, '-');
                  if O2c_BC.Bytecode_Mode then
                     if Res = T_Long then
                        raise O2c_BC.Wrong_Construct with "bytecode backend: "
                          & "LONGINT is not yet supported";
                     elsif Res = T_Int then
                        O2c_BC.Bin (O2c_BC.Sub);
                     elsif R.Typ /= T_Int and then X.Typ /= T_Int then
                        --  REAL and LONGREAL share the ops; both operands must be
                        --  non-integer, or an implicit I2R would be needed and the wrong
                        --  opcode would be silent.
                        O2c_BC.Bin (O2c_BC.Rsub);
                     else
                        raise O2c_BC.Wrong_Construct with "bytecode backend: "
                          & "a mixed INTEGER/REAL operation is not yet supported";
                     end if;
                  end if;
               elsif Real_Like (R, X, Res) then
                  declare
                     Conv : constant String :=
                       (if Res = T_LReal then "Long_Float (" else "Float (");
                  begin
                     if R.Typ = T_Int
                       or else (R.Typ = T_Real and then Res = T_LReal)
                     then
                        R.Text := To_Unbounded_String
                          (Conv & To_String (R.Text) & ")");
                     elsif X.Typ = T_Int
                       or else (X.Typ = T_Real and then Res = T_LReal)
                     then
                        X.Text := To_Unbounded_String
                          (Conv & To_String (X.Text) & ")");
                     end if;
                  end;
                  --  Both operands are real-valued here; a coerced
                  --  integer would need an I2R first and is refused.
                  if O2c_BC.Bytecode_Mode then
                     if R.Typ = T_Int or else X.Typ = T_Int then
                        raise O2c_BC.Wrong_Construct with "bytecode backend: "
                          & "a mixed INTEGER/REAL operation is not yet "
                          & "supported";
                     end if;
                     O2c_BC.Bin (O2c_BC.Rsub);
                  end if;
                  R.Text := R.Text & " - " & X.Text;
                  R.Typ := Res;
                  R.Lit := False;
                  Fold_Bin (R, X, '-');
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
               if O2c_BC.Bytecode_Mode then
                  raise O2c_BC.Wrong_Construct with
                    "bytecode backend: BOOLEAN operators are not yet "
                    & "supported";
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
            if (R.Typ /= T_Int and then R.Typ /= T_Char)
              or else X.Typ /= T_Set
            then
               raise O2c_Error with "IN needs an INTEGER/CHAR element and "
                 & "a SET operand (line " & Natural'Image (Cur.Line) & ")";
            end if;
            if O2c_BC.Bytecode_Mode then
               O2c_BC.Bin (O2c_BC.Set_In);
            end if;
            Used_Set := True;
            R.Text := To_Unbounded_String
              ("((" & To_String (X.Text)
               & " and O2c_Set (Interfaces.Shift_Left "
               & "(Interfaces.Unsigned_32 (1), "
               & (if R.Typ = T_Char
                  then "Character'Pos (" & To_String (R.Text) & ")"
                  else To_String (R.Text))
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
            Bc_O  : constant O2c_BC.Op :=
              (case Cur.Kind is
                 when Lex.Tok_Equal => O2c_BC.Eq,
                 when Lex.Tok_NE    => O2c_BC.Ne,
                 when Lex.Tok_LT    => O2c_BC.Lt,
                 when Lex.Tok_LE    => O2c_BC.Le,
                 when Lex.Tok_GT    => O2c_BC.Gt,
                 when others        => O2c_BC.Ge);
         begin
            Next;
            declare
               X  : Expr_Rec := Parse_Simple;
               Res : EType;
            begin
               if R.Typ = T_Str and then X.Typ = T_Str then
                  --  M33: string equality/ordering over NUL-terminated
                  --  content (char arrays may be padded with NULs)
                  Used_StrCmp := True;
                  if O2c_BC.Bytecode_Mode then
                     --  Both addresses are on the stack.  The three-way
                     --  compare gives -1/0/1; the relational against zero
                     --  gives whichever operator was asked for.
                     O2c_BC.Bin (O2c_BC.Str_Cmp);
                     O2c_BC.Push_Int (1);   --  0 less, 1 equal, 2 greater
                     O2c_BC.Bin (Bc_O);
                  end if;
                  R.Text := To_Unbounded_String
                    ("(O2c_S_Cmp (" & To_String (R.Text) & ", "
                     & To_String (X.Text) & ")" & Op & "0)");
                  R.Typ := T_Bool;
                  R.Lit := False;
                  return R;
               end if;
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
                        --  No bytecode emission here: this block only types
                        --  the comparison and returns a text rendering, and
                        --  it does not return - the general comparison below
                        --  emits the opcode.  Emitting here too produced two
                        --  comparisons for one expression, so the second one
                        --  compared the first one's result.

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
               elsif R.Typ = T_LReal
                 and then (X.Typ = T_Int or else X.Typ = T_Real)
               then
                  X.Text := To_Unbounded_String
                    ("Long_Float (" & To_String (X.Text) & ")");
               elsif (R.Typ = T_Int or else R.Typ = T_Real)
                 and then X.Typ = T_LReal
               then
                  R.Text := To_Unbounded_String
                    ("Long_Float (" & To_String (R.Text) & ")");
               end if;
               if O2c_BC.Bytecode_Mode then
                  --  the slice compares INTEGER and CHAR (CHAR shares
                  --  INTEGER's slot layout, so the I* opcodes apply)
                  --  REAL and LONGREAL compare with the R* opcodes; a
                  --  mixed INTEGER/REAL comparison needs an I2R first and
                  --  is refused rather than emitted wrong.
                  declare
                     Rl : constant Boolean :=
                       (R.Typ = T_Real or else R.Typ = T_LReal);
                     Pl : constant Boolean :=
                       ((R.Typ = T_Ptr or else R.Typ = T_Nil)
                        and then (X.Typ = T_Ptr or else X.Typ = T_Nil))
                       and then (R.Typ = T_Ptr or else X.Typ = T_Ptr)
                       and then (Op = " = " or else Op = " /= ");
                  begin
                     if not ((R.Typ = T_Int and then X.Typ = T_Int)
                             --  LONGINT is a 64-bit slot as INTEGER is, so
                             --  the same signed comparisons apply - and the
                             --  two mix, because a LONGINT against an integer
                             --  literal is the ordinary way to compare one.
                             or else ((R.Typ = T_Long or else R.Typ = T_Int)
                                      and then (X.Typ = T_Long
                                                or else X.Typ = T_Int))
                             or else (R.Typ = T_Char
                                      and then X.Typ = T_Char)
                             or else (Rl
                                      and then (X.Typ = T_Real
                                                or else X.Typ = T_LReal))
                             or else Pl)
                     then
                        raise O2c_BC.Wrong_Construct with "bytecode backend: "
                          & "only INTEGER/CHAR/REAL comparisons are supported, "
                          & "and pointers compare only with NIL";
                     end if;
                     if Op = " = " then
                        O2c_BC.Bin ((if Rl then O2c_BC.Req else O2c_BC.Eq));
                     elsif Op = " /= " then
                        O2c_BC.Bin ((if Rl then O2c_BC.Rne else O2c_BC.Ne));
                     elsif Op = " < " then
                        O2c_BC.Bin ((if Rl then O2c_BC.Rlt else O2c_BC.Lt));
                     elsif Op = " <= " then
                        O2c_BC.Bin ((if Rl then O2c_BC.Rle else O2c_BC.Le));
                     elsif Op = " > " then
                        O2c_BC.Bin ((if Rl then O2c_BC.Rgt else O2c_BC.Gt));
                     else
                        O2c_BC.Bin ((if Rl then O2c_BC.Rge else O2c_BC.Ge));
                     end if;
                  end;
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
      --  Recover the number, so a bytecode program can still name a constant.
      --  Text that is not a plain literal leaves Const_Usable false, and using
      --  it in bytecode mode is refused where the constant is used rather than
      --  silently reading a zero.
      if V.Folds then
         --  A folded INTEGER expression - a literal, a computed one, or a
         --  reference to another constant.  The value came through the
         --  parse, so nothing is recovered from the text here.
         Syms (N_Sym).Const_Val := V.Val;
         Syms (N_Sym).Const_Usable := True;
      elsif V.Lit and then (V.Typ = T_Int or else V.Typ = T_Char
                            or else V.Typ = T_Bool)
      then
         begin
            Syms (N_Sym).Const_Val :=
              Integer'Value (To_String (V.Text));
            Syms (N_Sym).Const_Usable := True;
         exception
            when others =>
               Syms (N_Sym).Const_Usable := False;
         end;
      end if;
      if Exp and then Pkg_Mode then
         if not V.Lit and then V.Typ /= T_Str then
            raise O2c_Error with "exported constants must be plain "
              & "literals (M19; '" & Name & "')";
         end if;
         if V.Typ /= T_Str and then not Scalar_Exportable (V.Typ) then
            raise O2c_Error with "exported constants: INTEGER/LONGINT/"
              & "REAL/CHAR/BOOLEAN/string only ('" & Name & "')";
         end if;
         Append_Spec ("   " & Ada_Id (Name) & " : constant "
                      & Ada_Type (V.Typ)
                      & " := " & To_String (V.Text) & ";");
         X_Add (To_String (Mod_Name),
                (Kind => S_Const, Typ => V.Typ,
                 Name => To_Unbounded_String (Name), others => <>));
      else
         Append_Decl ("   " & Name & " : constant " & Ada_Type (V.Typ)
                      & " := " & To_String (V.Text) & ";");
      end if;
   end Decl_Const;

   --  Parse `ARRAY <len> OF <elem>` and lay the type out.  Shared by a
   --  named TYPE declaration and by an inline array in a VAR, which has no
   --  name of its own: the layout is identical, only the name differs.
   procedure Parse_Array_Body (UTI : Natural; Name : String) is
   begin
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
            if UTypes (UTI).ExpT then
               Base_In_Spec := True;   --  M20e: base must be visible
            end if;
            Append_Decl ("   subtype " & Name & " is "
                         & (if UTypes (UTI).Elem = T_Int
                           then "O2c_Int_Arr"
                           else "O2c_Bool_Arr")
                         & " (0 .. "
                         & Integer'Image (UTypes (UTI).Arr_Len - 1) & ");");
         end if;
   end Parse_Array_Body;

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

      --  Bytecode: a procedure's variables are frame slots, taken after its
      --  parameters (which Begin_Proc interned first, in order).  They are
      --  interned here, at the declaration, rather than on first use, so a
      --  name that was never declared local cannot quietly become one.
      --  Gated on the *emitter's* procedure state rather than on In_Proc,
      --  which is set at the body's BEGIN: a procedure's declarations come
      --  before that, so the interning never ran for them and every local
      --  silently resolved to a global.  Proc_Open is true from Begin_Proc,
      --  which runs at the header, through End_Proc.
      if O2c_BC.Bytecode_Mode and then O2c_BC.Proc_Open then
         for I in 1 .. N loop
            declare
               Slot : constant Natural :=
                 O2c_BC.Local (Ada_Id (To_String (Names (I))));
               pragma Unreferenced (Slot);
            begin
               null;
            end;
         end loop;
      end if;
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
         if Cur.Kind = Lex.Tok_Array then
            --  An inline (anonymous) array type: `var v: array 4 of integer;`
            --  There is no name to declare it under, but the layout is exactly
            --  a named array's, so a type is synthesized and the same parser
            --  fills it.  The name cannot collide with source: it is not a
            --  legal identifier, so nothing can refer to it by accident.
            declare
               Img : constant String := Natural'Image (N_UT + 1);
            begin
               N_UT := N_UT + 1;
               if N_UT > UTypes'Last then
                  raise O2c_Error with "too many type declarations";
               end if;
               UT := N_UT;
               UTypes (UT) :=
                 (Name => To_Unbounded_String
                    ("O2c_Anon_Arr_" & Img (Img'First + 1 .. Img'Last)),
                  Is_Rec => True, others => <>);
               Parse_Array_Body (UT, To_String (UTypes (UT).Name));
               Is_UT := True;
            end;
         elsif Cur.Kind = Lex.Tok_Ident then
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
            --  Bytecode: an array, record or pointer variable needs storage
            --  wider than the scalar slot the backend emits for, and its
            --  element and field accesses are not emitted at all - an array
            --  subscript was silently dropped and the variable treated as a
            --  scalar.  Refusing here catches every such variable, since all
            --  of them come through this declaration.
            if O2c_BC.Bytecode_Mode then
               declare
                  Ok_Arr : constant Boolean :=
                    UTypes (UT).Arr_Len > 0
                    and then (UTypes (UT).Elem = T_Int
                              or else UTypes (UT).Elem = T_Char
                              or else UTypes (UT).Elem = T_Bool
                              or else UTypes (UT).Elem = T_Real);
                  Ok_Ptr : constant Boolean := UTypes (UT).Is_Ptr;
                  --  A procedure value is one slot - a procedure id - so a
                  --  variable of that type is as ordinary as a pointer.
                  Ok_Proc : constant Boolean := UTypes (UT).Is_Proc;
                  Ok_Rec : constant Boolean :=
                    UTypes (UT).Is_Rec
                    and then not UTypes (UT).Is_Ptr
                    and then UTypes (UT).Arr_Len = 0
                    and then UTypes (UT).N_F > 0
                    --  A field may be a scalar INTEGER, or one that names
                    --  the record itself - Oberon's implicit pointer, whose
                    --  default is null and which is how a list is built.
                    and then Chain_Fields_Allowed (UT);
               begin
                  if not (Ok_Arr or else Ok_Rec or else Ok_Ptr
                          or else Ok_Proc)
                  then
                     raise O2c_BC.Wrong_Construct with "bytecode backend: "
                       & "non-INTEGER arrays, record extensions and records "
                       & "with non-INTEGER or user-typed fields are not yet "
                       & "supported";
                  end if;
               end;
            end if;
            if UTypes (UT).Is_Ptr then
               Init_Txt := Init_Txt & "null";
            else
               Init_Txt := Init_Txt & Value_Init (UT);
            end if;
            for I in 1 .. N loop
               if Exps (I) then
                  --  M20f: only exported RECORD VARIABLEs export (whole
                  --  module-level records; fields are reached with '.')
                  if not (UTypes (UT).Is_Rec and then not UTypes (UT).Is_Ptr)
                  then
                     raise O2c_Error with "exported VARIABLEs: scalars or "
                       & "exported RECORD types only (M20f; '"
                       & To_String (Names (I)) & "')";
                  end if;
                  if not UTypes (UT).ExpT then
                     raise O2c_Error with "exported VARIABLE '"
                       & To_String (Names (I))
                       & "': its RECORD type must be exported (M20f)";
                  end if;
               end if;
               N_Sym := N_Sym + 1;
               Syms (N_Sym) := (Kind => S_Var, Typ => T_Int, UT => UT,
                                Name => Names (I), Exp => Exps (I),
                                others => <>);
               if Exps (I) and then Pkg_Mode then
                  --  M20f: emit after the type's primitive operations so
                  --  Ada keeps the dispatchers primitive (GNAT rule)
                  RVar_N := RVar_N + 1;
                  if RVar_N > RVar_Specs'Last then
                     raise O2c_Error with "too many exported RECORD "
                       & "VARIABLEs";
                  end if;
                  RVar_Specs (RVar_N) := To_Unbounded_String
                    ("   " & Ada_Id (To_String (Names (I))) & " : "
                     & Ada_Last (To_String (UTypes (UT).Name)) & " := "
                     & To_String (Init_Txt) & ";");
                  declare
                     E : X_Entry :=
                       (Kind => S_Var, Typ => T_Int,
                        Name => Names (I), others => <>);
                  begin
                     E.VT_Nm := To_Unbounded_String (Qual_UT (UT));
                     X_Add (To_String (Mod_Name), E);
                  end;
               else
                  Append_Decl ("   " & Ada_Id (To_String (Names (I)))
                               & " : "
                               & Ada_Last (To_String (UTypes (UT).Name))
                               & " := " & To_String (Init_Txt) & ";");
               end if;
            end loop;
         else
            for I in 1 .. N loop
               if Exps (I) and then
                 not (Scalar_Exportable (Typ) or else Typ = T_Set)
               then
                  raise O2c_Error with "exported VARIABLEs: INTEGER/"
                    & "LONGINT/REAL/CHAR/BOOLEAN/SET only (M21; '"
                    & To_String (Names (I)) & "')";
               end if;
               N_Sym := N_Sym + 1;
               Syms (N_Sym) := (Kind => S_Var, Typ => Typ,
                                Name => Names (I), Exp => Exps (I),
                                others => <>);
               if Exps (I) and then Pkg_Mode then
                  Append_Spec ("   " & Ada_Id (To_String (Names (I)))
                               & " : " & Ada_Type (Typ) & " := "
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

      if Cur.Kind = Lex.Tok_Procedure then
         --  A procedure type.  Minimal on purpose: no parameters and no
         --  result, so a value is just a procedure id with no environment.
         --  That is what makes it cheap - no closures, and the VM already
         --  numbers procedures.  Parameter lists are a later extension.
         Next;
         if Cur.Kind = Lex.Tok_LParen then
            raise O2c_Error with "procedure types with parameters are not "
              & "supported yet (line " & Natural'Image (Cur.Line) & ")";
         end if;
         UTypes (UTI).Is_Rec := False;
         UTypes (UTI).Is_Proc := True;
      elsif Cur.Kind = Lex.Tok_Array then
         Parse_Array_Body (UTI, Name);
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
               if UTypes (UTI).ExpT
                 and then not UTypes (TGT).ExpT
                 and then not UTypes (TGT).ForcedSpec
               then
                  raise O2c_Error with "opaque POINTER TO '"
                    & Name & "': declare its private RECORD after the "
                    & "pointer (M26)";
               end if;
               UTypes (UTI).Ptr_Tgt := TGT;
               Append_Decl ("   type " & Ada_Id (Name)
                         & " is access all " & Ada_Last (TName)
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
               PT  : Natural := 0;
               PNm : constant String := Cur.Text (1 .. Cur.Len);
            begin
               if Imported_Mod (PNm)
                 and then Lex.Peek_Token.Kind = Lex.Tok_Dot
               then
                  --  M23: extend an imported exported RECORD type
                  declare
                     Own : constant String := PNm;
                  begin
                     Next;         --  past the module name
                     Next;         --  past '.'
                     Expect (Lex.Tok_Ident, "an exported type name");
                     PT := Import_Type (Own, Cur.Text (1 .. Cur.Len));
                     Next;
                  end;
               else
                  PT := Find_UT (PNm);
                  Next;
               end if;
               if PT = 0 then
                  raise O2c_Error with "unknown parent record type '"
                    & PNm & "' (line "
                    & Natural'Image (Cur.Line) & ")";
               end if;
               if not UTypes (PT).Is_Rec or else UTypes (PT).Is_Ptr
               then
                  raise O2c_Error with "'" & To_String (UTypes (PT).Name)
                    & "' is not an extensible RECORD type (line "
                    & Natural'Image (Cur.Line) & ")";
               end if;
               UTypes (UTI).Is_Ext := True;
               UTypes (UTI).Parent := PT;
            end;
            Expect (Lex.Tok_RParen, "')' after the parent record type");
            Next;
         end if;
         loop
            exit when Cur.Kind = Lex.Tok_End;
            declare
               FNames : array (1 .. 16) of Unbounded_String;
               FExp   : array (1 .. 16) of Boolean := (others => False);
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
                  if Cur.Kind = Lex.Tok_Star then
                     FExp (NF) := True;   --  exported field mark (M22)
                     Next;
                  end if;
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
                  if Imported_Mod (TN)
                    and then Lex.Peek_Token.Kind = Lex.Tok_Dot
                  then
                     --  M24: field of an imported exported type
                     declare
                        Own : constant String := TN;
                     begin
                        Next;          --  past the module name
                        Next;          --  past '.'
                        Expect (Lex.Tok_Ident, "an exported type name");
                        FUT := Import_Type (Own, Cur.Text (1 .. Cur.Len));
                        FT := T_Int;
                        Next;
                     end;
                  else
                     FT := Builtin_Type_Of (TN);
                     if FT = T_Str then
                        FUT := Find_UT (TN);
                        if FUT = 0 then
                           raise O2c_Error with "field types: INTEGER/"
                             & "BOOLEAN/CHAR or an earlier user type ('"
                             & TN & "')";
                        end if;
                        FT := T_Int;  --  scalar slot unused for user types
                     end if;
                     Next;
                  end if;
               end;
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
                    (Name => FNames (I), Typ => FT, UT => FUT,
                     ExpF => FExp (I));
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
            OpaqueT    : Boolean := False;
         begin
            --  M26: if an exported POINTER TO this private record was
            --  declared earlier, the whole pair must live in the spec.
            for P in 1 .. N_UT loop
               if UTypes (P).Is_Ptr and then UTypes (P).Pend
                 and then To_String (UTypes (P).Pend_Nm) = Name
                 and then UTypes (P).ExpT
                 and then not UTypes (UTI).ExpT
               then
                  OpaqueT := True;
               end if;
            end loop;
            if OpaqueT then
               UTypes (UTI).ForcedSpec := True;
               Spec_Decl := True;
               for F in 1 .. UTypes (UTI).N_F loop
                  if UTypes (UTI).F (F).UT /= 0
                    and then not UTypes (UTypes (UTI).F (F).UT).ExpT
                    and then not UTypes (UTypes (UTI).F (F).UT).Imported
                  then
                     raise O2c_Error with "opaque target '" & Name
                       & "': field '" & To_String (UTypes (UTI).F (F).Name)
                       & "' must be scalar or an exported/imported type "
                       & "to appear in the spec (M26)";
                  end if;
               end loop;
            end if;
            for P in 1 .. N_UT loop
               if UTypes (P).Is_Ptr and then UTypes (P).Pend
                 and then To_String (UTypes (P).Pend_Nm) = Name
               then
                  if First_Pend then
                     Append_Decl ("   type " & Ada_Id (Name) & ";");
                     First_Pend := False;
                  end if;
                  UTypes (P).Ptr_Tgt := UTI;
                  UTypes (P).Pend := False;
                  Append_Decl ("   type "
                               & Ada_Id (To_String (UTypes (P).Name))
                               & " is access all " & Ada_Id (Name)
                               & "'Class;");
               end if;
            end loop;
         end;
         Append_Decl ("   type " & Ada_Id (Name)
                      & (if UTypes (UTI).Is_Ext then
                           " is new " & Ada_Last (To_String
                             (UTypes (UTypes (UTI).Parent).Name))
                           & " with record"
                         else " is tagged record"));
         for F in 1 .. UTypes (UTI).N_F loop
            declare
               Fl : UField renames UTypes (UTI).F (F);
            begin
               Append_Decl ("      " & Ada_Id (To_String (Fl.Name))
                            & " : "
                            & (if Fl.UT /= 0
                              then Ada_Last (To_String (UTypes (Fl.UT).Name))
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
            return Ada_Last (To_String (UTypes (Recv_UT).Name))
              & "'Class";
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
            return Ada_Last (To_String (UTypes (PUT (I)).Name));
         else
            return Ada_Type (PTyp (I));
         end if;
      end Formal_Ada_Type;
   begin
      if Recv_UT /= 0 then
         if UTypes (Recv_UT).Imported then
            raise O2c_Error with "type-bound procedures on an imported "
              & "RECORD type must be declared in that module (M23; '"
              & Name & "')";
         end if;
         --  type-bound procedure: receiver is formal parameter #1
         Impl_Nm := To_Unbounded_String (Method_Impl_Name (Name, Recv_UT));
         N_Par := 1;
         PName (1) := Recv_Nm;
         PTyp (1) := T_Int;
         PUT (1) := Recv_UT;
         PRef (1) := Recv_Var;
         POpen (1) := False;
      else
         Impl_Nm := To_Unbounded_String (Ada_Id (Name));
      end if;
      Seen_Proc := True;
      Next;                       --  past the procedure name
      Exported := False;
      if Cur.Kind = Lex.Tok_Star then
         Exported := True;        --  export mark (M19)
         Next;
      end if;
      if Exported and then Nested_Depth > 0 then
         raise O2c_Error with "procedures cannot be exported inside a "
           & "procedure ('" & Name & "')";
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
      --  EXTERN "symbol" is parsed here, at the end of the heading: this
      --  procedure is not Oberon code but a binding to a C function.  The
      --  symbol resolves now, so a name the VM does not know is a compile
      --  error naming it rather than a call to whatever id sits nearby.
      Foreign_Sym := Null_Unbounded_String;
      Foreign_Id_Val := 0;
      if Cur.Kind = Lex.Tok_Extern then
         Next;
         if Cur.Kind /= Lex.Tok_String then
            raise O2c_Error with "a string literal expected after EXTERN "
              & "(line " & Natural'Image (Cur.Line) & ")";
         end if;
         Foreign_Sym := To_Unbounded_String (Cur.Text (1 .. Cur.Len));
         Foreign_Id_Val := O2c_BC.Foreign_Id (Cur.Text (1 .. Cur.Len));
         if Foreign_Id_Val = 0 then
            raise O2c_Error with "the VM has no foreign function named '"
              & Cur.Text (1 .. Cur.Len) & "' (line "
              & Natural'Image (Cur.Line) & ")";
         end if;
         Next;
      end if;
      Expect (Lex.Tok_Semi, "';' after the procedure header");
      Next;

      N_Sym := N_Sym + 1;
      Syms (N_Sym) := (Kind => S_Proc, Name => To_Unbounded_String (Name),
                       Params => N_Par, Typ => Ret_Typ, UT => Ret_UT,
                       Ret => Is_Function, Exp => Exported,
                       Foreign => Foreign_Sym,
                       Foreign_Native => Foreign_Id_Val, others => <>);
      for I in 1 .. N_Par loop
         Syms (N_Sym).P (I) :=
           (Name => PName (I), Typ => PTyp (I), By_Ref => PRef (I),
            UT => PUT (I), Open => POpen (I));
      end loop;
         if O2c_BC.Bytecode_Mode and then not O2c_BC.Proc_Open then
            declare
               --  Each open-array formal contributes two values at a call -
               --  the array's address and its length - so the count the
               --  emitter balances against is slots, not parameters.
               N_Open : Natural := 0;
            begin
               for I in 1 .. N_Par loop
                  if POpen (I) then
                     N_Open := N_Open + 1;
                  end if;
               end loop;
               Syms (N_Sym).Bc_Proc :=
                 O2c_BC.Begin_Proc (N_Par + N_Open,
                                    (if Is_Function then 1 else 0));
            end;
         end if;

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
         --  M20c/M27: exported type-bound method.  Its dispatcher is
         --  exported from the package spec; plain procedures keep the
         --  M19/M20b path below.  When the (exported) receiver extends
         --  an imported RECORD and overrides one of its exported
         --  methods, this module's dispatcher is what importers call,
         --  so the override dispatches for types seen through this
         --  module (M27).
         if not UTypes (Recv_UT).ExpT then
            raise O2c_Error with "type-bound procedure '" & Name
              & "' can be exported only on an exported type (M20c)";
         end if;
         for I in 2 .. N_Par loop
            if POpen (I) and then PTyp (I) = T_Set then
               raise O2c_Error with "exported method '" & Name
                 & "': SET-element ARRAY OF parameters are not "
                 & "exportable (M21)";
            end if;
            --  M48: SET parameters export now that every unit shares
            --  O2c_Types.O2c_Set (Mouse in the Oakwood Input module).
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
                  --  M20e: a named fixed ARRAY formal exports as VAR
                  if not PRef (I) then
                     raise O2c_Error with "exported method '" & Name
                       & "': ARRAY parameters must be declared VAR (M20e)";
                  end if;
                  if UTypes (PUT (I)).Elem = T_Set then
                     raise O2c_Error with "exported method '" & Name
                       & "': SET-element ARRAY parameters are not "
                       & "exportable (M20e)";
                  end if;
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
            if POpen (I) and then PTyp (I) = T_Set then
               raise O2c_Error with "exported procedure '" & Name
                 & "': SET-element ARRAY OF parameters are not "
                 & "exportable (M21)";
            end if;
            --  M48: SET parameters export now that every unit shares
            --  O2c_Types.O2c_Set (Mouse in the Oakwood Input module).
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
                  --  M20e: a named fixed ARRAY formal exports as VAR
                  if not PRef (I) then
                     raise O2c_Error with "exported procedure '" & Name
                       & "': ARRAY parameters must be declared VAR (M20e)";
                  end if;
                  if UTypes (PUT (I)).Elem = T_Set then
                     raise O2c_Error with "exported procedure '" & Name
                       & "': SET-element ARRAY parameters are not "
                       & "exportable (M20e)";
                  end if;
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
                              UT => 0, By_Ref => PRef (I), Open => POpen (I));
                  if PUT (I) /= 0 then
                     E.P_Nm (I) := To_Unbounded_String (Qual_UT (PUT (I)));
                  end if;
               end loop;
               if Ret_UT /= 0 then
                  E.Ret_Nm := To_Unbounded_String (Qual_UT (Ret_UT));
               end if;
               X_Add (To_String (Mod_Name), E);
            end;
         end if;
      end if;
      Append_Decl (To_String (Hdr) & " is");
      --  Bytecode: a declared procedure is its own procedure in the CODE
      --  section.  Its parameters become the lowest frame slots, in order,
      --  which is the convention CALL relies on: a callee's locals ARE its
      --  parameter slots, lowest slot first.  The names are interned under
      --  the same spelling the use sites look up, i.e. Ada_Id-mangled.
      if O2c_BC.Bytecode_Mode then
         for I in 1 .. N_Par loop
            declare
               --  The slot value is held by the emitter's own table; all
               --  this needs is the interning side effect, in parameter
               --  order.
               Slot : constant Natural :=
                 O2c_BC.Local (Ada_Id (To_String (PName (I))));
               pragma Unreferenced (Slot);
            begin
               null;
            end;
            if POpen (I) then
               --  An open array's length is unknown to the callee, so it
               --  travels with the array as a second slot, immediately
               --  after the address.  Every later parameter therefore sits
               --  one slot higher, which is the whole reason the convention
               --  has to be spelled out rather than assumed.
               declare
                  Slot : constant Natural :=
                    O2c_BC.Local ("#alen-" & Ada_Id (To_String (PName (I))));
                  pragma Unreferenced (Slot);
               begin
                  null;
               end;
            end if;
         end loop;
      end if;
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
         elsif Cur.Kind = Lex.Tok_Procedure then
            --  M32: nested procedure (no receiver, no export)
            declare
               Save_Recv : constant Natural := Recv_UT;
            begin
               Next;              --  past PROCEDURE
               if Cur.Kind = Lex.Tok_LParen then
                  raise O2c_Error with "local type-bound procedures are "
                    & "not supported (inside " & Name & ", line "
                    & Natural'Image (Cur.Line) & ")";
               end if;
               Recv_UT := 0;
               Nested_Depth := Nested_Depth + 1;
               Decl_Procedure;
               Nested_Depth := Nested_Depth - 1;
               Recv_UT := Save_Recv;
            end;
         else
            raise O2c_Error with "expected CONST/TYPE/VAR/PROCEDURE or "
              & "BEGIN in procedure " & Name & " (line "
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
      if Cur.Kind /= Lex.Tok_Begin
        and then Length (Foreign_Sym) = 0
      then
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
      if O2c_BC.Bytecode_Mode then
         --  A procedure that falls off its end returns no value.  A function
         --  must end with RETURN (the front end enforces it above), and that
         --  statement emits the return itself.
         if not Is_Function then
            O2c_BC.Return_Void;
         end if;
         O2c_BC.End_Proc;
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
      L_End  : Natural := 0;         --  after the whole IF
      L_Next : Natural := 0;         --  this branch's alternate
   begin
      if O2c_BC.Bytecode_Mode then
         L_End := New_Bc_Label;
      end if;
      loop
         Next;                       --  consume IF / ELSIF
         Cond := Parse_Expr;
         if Cond.Typ /= T_Bool then
            raise O2c_Error with "IF/ELSIF condition must be BOOLEAN (line "
              & Natural'Image (Cur.Line) & ")";
         end if;
         Expect (Lex.Tok_Then, "'THEN'");
         Next;
         if O2c_BC.Bytecode_Mode then
            L_Next := New_Bc_Label;
            O2c_BC.Jump (O2c_BC.Jz, L_Next);
         end if;
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
         if O2c_BC.Bytecode_Mode then
            O2c_BC.Jump (O2c_BC.Jmp, L_End);
            O2c_BC.Mark (L_Next);
         end if;
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
      if O2c_BC.Bytecode_Mode then
         O2c_BC.Mark (L_End);
      end if;
      Append_Body ("      end if;");
   end Parse_If;

   procedure Parse_While is
      Cond  : Expr_Rec;
      L_Top : Natural := 0;
      L_End : Natural := 0;
   begin
      Next;                          --  WHILE
      if O2c_BC.Bytecode_Mode then
         L_Top := New_Bc_Label;
         L_End := New_Bc_Label;
         O2c_BC.Mark (L_Top);
      end if;
      Cond := Parse_Expr;
      if Cond.Typ /= T_Bool then
         raise O2c_Error with "WHILE condition must be BOOLEAN (line "
           & Natural'Image (Cur.Line) & ")";
      end if;
      Expect (Lex.Tok_Do, "'DO'");
      Next;
      if O2c_BC.Bytecode_Mode then
         O2c_BC.Jump (O2c_BC.Jz, L_End);
      end if;
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
      if O2c_BC.Bytecode_Mode then
         O2c_BC.Jump (O2c_BC.Jmp, L_Top);
         O2c_BC.Mark (L_End);
      end if;
      Append_Body ("      end loop;");
   end Parse_While;

   procedure Parse_Repeat is
      Cond  : Expr_Rec;
      L_Top : Natural := 0;
   begin
      Next;                          --  REPEAT
      if O2c_BC.Bytecode_Mode then
         L_Top := New_Bc_Label;
         O2c_BC.Mark (L_Top);
      end if;
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
      if O2c_BC.Bytecode_Mode then
         --  The Ada body exits when the condition holds, so the bytecode
         --  jumps back to the top when it does NOT: JZ is the mirror of
         --  WHILE's exit test.
         O2c_BC.Jump (O2c_BC.Jz, L_Top);
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
         L_End  : constant Natural := New_Bc_Label;
      begin
         if O2c_BC.Bytecode_Mode then
            --  Oberon's WITH runs the body only if the object's dynamic type
            --  is the guard's, or an extension of it, and *skips* it when
            --  not - which is why this is a test and a branch rather than
            --  GUARD, whose trap belongs to the v(T) form.  Without it the
            --  body ran regardless: it printed the right answer for a
            --  matching object and the wrong one silently for any other.
            Bc_Load (VName (1 .. V_Len));
            O2c_BC.Type_Test (Desc_For (GT));
            O2c_BC.Jump (O2c_BC.Jz, L_End);
         end if;
         Statement_Seq;              --  until END
         if O2c_BC.Bytecode_Mode then
            O2c_BC.Mark (L_End);
         end if;
         if Length (Body_Buf) = Before then
            Append_Body ("         null;");
         end if;
      end;
      G_N := G_N - 1;
      Expect (Lex.Tok_End, "'END' closing the WITH");
      Next;
   end Parse_With;

   Bc_For_N : Natural := 0;   --  numbered so nested FOR slots cannot collide

   procedure Parse_For is
      V_Name : String (1 .. 64);
      V_Len  : Natural;
      Idx    : Natural;
      Lo, Hi : Expr_Rec;
      By_Text : Unbounded_String;
      Asc    : Boolean;
      --  Bytecode: the loop variable is a frame slot (the opcodes address
      --  frames, not globals), followed by two synthesized slots for the
      --  limit and the direction.  Nested loops get their own, so the names
      --  carry a counter; they cannot collide with Oberon identifiers
      --  because they start with '#'.
      Had_By : Boolean := False;
      Bc_Slot  : Natural := 0;
      Bc_Limit : Natural := 0;
      Bc_Top   : Natural := 0;
      Bc_Else  : Natural := 0;
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
      Had_By := Cur.Kind = Lex.Tok_By;
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
      if O2c_BC.Bytecode_Mode then
         Bc_Slot := O2c_BC.Local (Ada_Id (V_Name (1 .. V_Len)));
         declare
            --  The two hidden slots are interned together and in this order,
            --  so the direction is always the limit's next slot.  The limit
            --  is *named* by the FOR opcodes rather than assumed to sit just
            --  after the loop variable: with a procedure's declared locals
            --  interned first, that slot belongs to someone else.
            Lim : constant Natural :=
              O2c_BC.Local ("#for-limit-" & Natural'Image (Bc_For_N));
            Dir : constant Natural :=
              O2c_BC.Local ("#for-dir-" & Natural'Image (Bc_For_N));
            pragma Unreferenced (Dir);
         begin
            Bc_Limit := Lim;
         end;
         Bc_For_N := Bc_For_N + 1;
         Bc_Top := New_Bc_Label;
         Bc_Else := New_Bc_Label;
         --  BY's expression pushed a value on the operand stack; the step
         --  comes from its text (the front end has checked it is an integer
         --  constant), so the pushed value goes.
         if Had_By then
            O2c_BC.Discard;
         end if;
         --  from and to are on the stack, to on top
         O2c_BC.For_Enter (Bc_Slot, Integer'Value (To_String (By_Text)),
                           Bc_Limit, Bc_Else);
         O2c_BC.Mark (Bc_Top);
      end if;
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
      if O2c_BC.Bytecode_Mode then
         O2c_BC.For_Next (Bc_Slot, Integer'Value (To_String (By_Text)),
                          Bc_Limit, Bc_Top);
         O2c_BC.Mark (Bc_Else);
         --  The loop variable lived in a frame slot; a module variable has
         --  to carry the final value back to its global.
         if not In_Proc then
            O2c_BC.Load_Local (Bc_Slot);
            O2c_BC.Store (O2c_BC.Global (Ada_Id (V_Name (1 .. V_Len))));
         end if;
      end if;
   end Parse_For;

   procedure Parse_Case is
      Sel : Expr_Rec;
      Used_Else : Boolean := False;
      Bc_L_End  : Natural := 0;
      Bc_L_Next : Natural := 0;   --  where a failed alternative resumes
      Bc_L_Body : Natural := 0;
   begin
      Next;                       --  CASE
      Sel := Parse_Expr;
      if Sel.Typ /= T_Int then
         raise O2c_Error with "CASE selector must be INTEGER (line "
           & Natural'Image (Cur.Line) & ")";
      end if;
      Expect (Lex.Tok_Of, "'OF'");
      Next;
      if O2c_BC.Bytecode_Mode then
         --  A CASE is a comparison chain over the selector, which stays on
         --  the stack for the whole statement and is dropped once at the
         --  end.  Bc_L_Next is where a failed alternative resumes: it is
         --  allocated here and marked at the start of the next alternative,
         --  never at its own - marking it at its own made the failed
         --  comparisons re-run, which looped.
         Bc_L_End := New_Bc_Label;
         Bc_L_Next := New_Bc_Label;
      end if;
      Append_Body ("      case " & To_String (Sel.Text) & " is");

      --  alternatives: label {"," label} ":" seq  separated by "|",
      --  optional ELSE, closed by END
      loop
         if O2c_BC.Bytecode_Mode then
            O2c_BC.Mark (Bc_L_Next);
            Bc_L_Next := New_Bc_Label;
         end if;
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
                     if O2c_BC.Bytecode_Mode then
                        if First then
                           Bc_L_Body := New_Bc_Label;
                        end if;
                        O2c_BC.Dup_Top;
                        O2c_BC.Push_Int
                          (-Integer'Value (Cur.Text (1 .. Cur.Len)));
                        O2c_BC.Bin (O2c_BC.Eq);
                        O2c_BC.Jump (O2c_BC.Jnz, Bc_L_Body);
                     end if;
                     Next;
                  elsif Cur.Kind = Lex.Tok_Number then
                     if First then
                        Labels := To_Unbounded_String (Cur.Text (1 .. Cur.Len));
                     else
                        Labels := Labels & " | " & Cur.Text (1 .. Cur.Len);
                     end if;
                     if O2c_BC.Bytecode_Mode then
                        if First then
                           Bc_L_Body := New_Bc_Label;
                        end if;
                        O2c_BC.Dup_Top;
                        O2c_BC.Push_Int (Integer'Value (Cur.Text (1 .. Cur.Len)));
                        O2c_BC.Bin (O2c_BC.Eq);
                        O2c_BC.Jump (O2c_BC.Jnz, Bc_L_Body);
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
               if O2c_BC.Bytecode_Mode then
                  O2c_BC.Jump (O2c_BC.Jmp, Bc_L_Next);
               end if;
               Append_Body ("      when " & To_String (Labels) & " =>");
            end;
         end if;

         if O2c_BC.Bytecode_Mode and then not Used_Else then
            O2c_BC.Mark (Bc_L_Body);
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

         if O2c_BC.Bytecode_Mode then
            O2c_BC.Jump (O2c_BC.Jmp, Bc_L_End);
         end if;

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
      if O2c_BC.Bytecode_Mode then
         O2c_BC.Mark (Bc_L_Next);     --  the last alternative's skip lands here
         O2c_BC.Mark (Bc_L_End);
         O2c_BC.Discard;
      end if;
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
         --  Procedure bodies used to be rejected here because they would
         --  land in the body's code buffer.  Decl_Procedure now brackets
         --  each one with Begin_Proc/End_Proc, so a procedure's code is its
         --  own extent in the CODE payload and the module body comes last.

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
                  elsif Cur_Ret_Type = T_LReal and then V.Typ = T_Int then
                     V.Text := To_Unbounded_String
                       ("Long_Float (" & To_String (V.Text) & ")");
                  elsif Cur_Ret_Type = T_LReal and then V.Typ = T_Real then
                     V.Text := To_Unbounded_String
                       ("Long_Float (" & To_String (V.Text) & ")");
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
            --  Bytecode: the value (a function) is already on the operand
            --  stack from the expression's own hooks, so the return is the
            --  last step.  Cur_Proc_Ret says which kind of return this is.
            if O2c_BC.Bytecode_Mode then
               if Cur_Proc_Ret then
                  O2c_BC.Return_Value;
               else
                  O2c_BC.Return_Void;
               end if;
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
            if To_String (Mod_Name) = "Convert"
              and then (Eq_No_Case (Head (1 .. H_Len), "CONVTOINT")
                        or else Eq_No_Case (Head (1 .. H_Len),
                                            "CONVTOREAL")
                        or else Eq_No_Case (Head (1 .. H_Len),
                                            "CONVFROMINT"))
            then
               --  Refused in bytecode mode rather than silently emitting
               --  nothing: this branch appends to the Ada body and makes no
               --  O2c_BC call at all, so a bytecode program would compile,
               --  run, and quietly do nothing at all.
               if O2c_BC.Bytecode_Mode then
                  raise O2c_BC.Wrong_Construct with "bytecode backend: "
                    & "Convert.ConvToInt/ConvToReal/ConvFromInt are not yet supported";
               end if;
               --  M52 FFI: number <-> string (builtin Convert only)
               declare
                  Kind : constant String := Head (1 .. H_Len);
                  P1, P2, P3 : Expr_Rec;
               begin
                  if Eq_No_Case (Kind, "CONVFROMINT") then
                     Next;
                     Expect (Lex.Tok_LParen, "'(' after ConvFromInt");
                     Next;
                     P1 := Parse_Expr;
                     if P1.Typ /= T_Int then
                        raise O2c_Error with "ConvFromInt needs an INTEGER";
                     end if;
                     Expect (Lex.Tok_Comma, "','");
                     Next;
                     P2 := Parse_Expr;
                     if P2.Typ /= T_Str then
                        raise O2c_Error with "ConvFromInt needs an ARRAY "
                          & "OF CHAR buffer";
                     end if;
                     Expect (Lex.Tok_RParen, "')'");
                     Next;
                     Append_Body ("      O2c_Conv_FromInt ("
                                  & To_String (P1.Text) & ", "
                                  & To_String (P2.Text) & ");");
                  else
                     Next;
                     Expect (Lex.Tok_LParen, "'(' after the Convert call");
                     Next;
                     P1 := Parse_Expr;
                     if P1.Typ /= T_Str then
                        raise O2c_Error with "an ARRAY OF CHAR value is "
                          & "required";
                     end if;
                     Expect (Lex.Tok_Comma, "','");
                     Next;
                     P2 := Parse_Expr;
                     Expect (Lex.Tok_Comma, "','");
                     Next;
                     P3 := Parse_Expr;
                     if P3.Typ /= T_Int then
                        raise O2c_Error with "the result must be an INTEGER "
                          & "variable";
                     end if;
                     Expect (Lex.Tok_RParen, "')'");
                     Next;
                     Append_Body ("      "
                                  & (if Eq_No_Case (Kind, "CONVTOINT")
                                     then "O2c_Conv_ToInt ("
                                     else "O2c_Conv_ToReal (")
                                  & To_String (P1.Text) & ", "
                                  & To_String (P2.Text) & ", "
                                  & To_String (P3.Text) & ");");
                  end if;
               end;
            elsif To_String (Mod_Name) = "Env"
              and then (Eq_No_Case (Head (1 .. H_Len), "ENVGET")
                        or else Eq_No_Case (Head (1 .. H_Len), "ENVSET"))
            then
               --  M51 FFI: environment access (builtin Env only).
               --  Refused in bytecode mode rather than silently emitting
               --  nothing: this branch appends to the Ada body and makes no
               --  O2c_BC call at all, so a bytecode program would compile,
               --  run, and quietly not read its environment.  Today that is
               --  masked - an ARRAY OF CHAR module variable is itself
               --  rejected in bytecode mode, so control never arrives here -
               --  which is exactly why it is worth refusing now: the moment
               --  that restriction is lifted, this becomes a silent no-op.
               if O2c_BC.Bytecode_Mode then
                  raise O2c_BC.Wrong_Construct with "bytecode backend: "
                    & "Env.EnvGet/EnvSet are not yet supported";
               end if;
               declare
                  Is_Get : constant Boolean :=
                    Eq_No_Case (Head (1 .. H_Len), "ENVGET");
                  P1, P2 : Expr_Rec;
               begin
                  Next;
                  Expect (Lex.Tok_LParen, "'(' after the Env call");
                  Next;
                  P1 := Parse_Expr;
                  if P1.Typ /= T_Str then
                     raise O2c_Error with "an ARRAY OF CHAR name is required";
                  end if;
                  Expect (Lex.Tok_Comma, "','");
                  Next;
                  P2 := Parse_Expr;
                  if P2.Typ /= T_Str then
                     raise O2c_Error with "an ARRAY OF CHAR value is required";
                  end if;
                  Expect (Lex.Tok_RParen, "')'");
                  Next;
                  Append_Body ("      "
                               & (if Is_Get then "O2c_Env_Get ("
                                  else "O2c_Env_Set (")
                               & To_String (P1.Text) & ", "
                               & To_String (P2.Text) & ");");
               end;
            elsif To_String (Mod_Name) = "Args"
              and then Eq_No_Case (Head (1 .. H_Len), "ARGGET")
            then
               --  Refused in bytecode mode rather than silently emitting
               --  nothing: this branch appends to the Ada body and makes no
               --  O2c_BC call at all, so a bytecode program would compile,
               --  run, and quietly do nothing at all.
               if O2c_BC.Bytecode_Mode then
                  raise O2c_BC.Wrong_Construct with "bytecode backend: "
                    & "Args.ArgGet are not yet supported";
               end if;
               --  M50 FFI: argument fetch (builtin Args only)
               declare
                  P1, P2, P3 : Expr_Rec;
               begin
                  Next;
                  Expect (Lex.Tok_LParen, "'(' after ArgGet");
                  Next;
                  P1 := Parse_Expr;
                  if P1.Typ /= T_Int then
                     raise O2c_Error with "ArgGet needs an INTEGER index";
                  end if;
                  Expect (Lex.Tok_Comma, "','");
                  Next;
                  P2 := Parse_Expr;
                  if P2.Typ /= T_Str then
                     raise O2c_Error with "ArgGet needs an ARRAY OF CHAR "
                       & "buffer";
                  end if;
                  Expect (Lex.Tok_Comma, "','");
                  Next;
                  P3 := Parse_Expr;
                  if P3.Typ /= T_Int then
                     raise O2c_Error with "ArgGet needs an INTEGER result";
                  end if;
                  Expect (Lex.Tok_RParen, "')'");
                  Next;
                  Append_Body ("      O2c_Arg_Get (" & To_String (P1.Text)
                               & ", " & To_String (P2.Text) & ", "
                               & To_String (P3.Text) & ");");
               end;
            elsif To_String (Mod_Name) = "XYplane"
              and then (Eq_No_Case (Head (1 .. H_Len), "PLANEOPEN")
                        or else Eq_No_Case (Head (1 .. H_Len),
                                            "PLANECLEAR")
                        or else Eq_No_Case (Head (1 .. H_Len), "PLANEDOT"))
            then
               --  Refused in bytecode mode rather than silently emitting
               --  nothing: this branch appends to the Ada body and makes no
               --  O2c_BC call at all, so a bytecode program would compile,
               --  run, and quietly do nothing at all.
               if O2c_BC.Bytecode_Mode then
                  raise O2c_BC.Wrong_Construct with "bytecode backend: "
                    & "XYplane.PlaneOpen/PlaneClear/PlaneDot are not yet supported";
               end if;
               --  M49 FFI: plane operations (builtin XYplane only)
               if Eq_No_Case (Head (1 .. H_Len), "PLANECLEAR") then
                  Next;
                  if Cur.Kind = Lex.Tok_LParen then
                     Next;
                     Expect (Lex.Tok_RParen, "')'");
                     Next;
                  end if;
                  Append_Body ("      O2c_Plane_Clear;");
               else
                  declare
                     Is_Open : constant Boolean :=
                       Eq_No_Case (Head (1 .. H_Len), "PLANEOPEN");
                     P1, P2, P3 : Expr_Rec;
                  begin
                     Next;
                     Expect (Lex.Tok_LParen, "'(' after the plane call");
                     Next;
                     P1 := Parse_Expr;
                     Expect (Lex.Tok_Comma, "','");
                     Next;
                     P2 := Parse_Expr;
                     if Is_Open then
                        Expect (Lex.Tok_RParen, "')'");
                        Next;
                        Append_Body ("      O2c_Plane_Open ("
                                     & To_String (P1.Text) & ", "
                                     & To_String (P2.Text) & ");");
                     else
                        Expect (Lex.Tok_Comma, "','");
                        Next;
                        P3 := Parse_Expr;
                        Expect (Lex.Tok_RParen, "')'");
                        Next;
                        Append_Body ("      O2c_Plane_Dot ("
                                     & To_String (P1.Text) & ", "
                                     & To_String (P2.Text) & ", "
                                     & To_String (P3.Text) & ");");
                     end if;
                  end;
               end if;
            elsif To_String (Mod_Name) = "In"
              and then (Eq_No_Case (Head (1 .. H_Len), "INOPEN")
                        or else Eq_No_Case (Head (1 .. H_Len), "INSTRING")
                        or else Eq_No_Case (Head (1 .. H_Len), "INNAME"))
            then
               --  Refused in bytecode mode rather than silently emitting
               --  nothing: this branch appends to the Ada body and makes no
               --  O2c_BC call at all, so a bytecode program would compile,
               --  run, and quietly do nothing at all.
               if O2c_BC.Bytecode_Mode then
                  raise O2c_BC.Wrong_Construct with "bytecode backend: "
                    & "In.InReset/InString/InName are not yet supported";
               end if;
               --  M45 FFI: input statements (builtin In module only)
               if Eq_No_Case (Head (1 .. H_Len), "INOPEN") then
                  Next;
                  if Cur.Kind = Lex.Tok_LParen then
                     Next;
                     Expect (Lex.Tok_RParen, "')'");
                     Next;
                  end if;
                  Append_Body ("      O2c_In_Reset;");
               else
                  declare
                     Is_Name : constant Boolean :=
                       Eq_No_Case (Head (1 .. H_Len), "INNAME");
                  begin
                     Next;
                     Expect (Lex.Tok_LParen, "'(' after the input call");
                     Next;
                     declare
                        A : Expr_Rec := Parse_Expr;
                     begin
                        if A.Typ /= T_Str then
                           raise O2c_Error with "an ARRAY OF CHAR buffer "
                             & "is required";
                        end if;
                        Expect (Lex.Tok_RParen, "')'");
                        Next;
                        Append_Body ("      "
                                     & (if Is_Name then "O2c_In_Name"
                                        else "O2c_In_Word")
                                     & " (" & To_String (A.Text) & ");");
                     end;
                  end;
               end if;
            elsif To_String (Mod_Name) = "Files"
              and then Eq_No_Case (Head (1 .. H_Len), "FDEL")
            then
               --  Refused in bytecode mode rather than silently emitting
               --  nothing: this branch appends to the Ada body and makes no
               --  O2c_BC call at all, so a bytecode program would compile,
               --  run, and quietly do nothing at all.
               if O2c_BC.Bytecode_Mode then
                  raise O2c_BC.Wrong_Construct with "bytecode backend: "
                    & "Files.FDel are not yet supported";
               end if;
               --  M42 FFI: delete a named file (builtin Files only)
               declare
                  P1 : Expr_Rec;
               begin
                  Next;
                  Expect (Lex.Tok_LParen, "'(' after FDel");
                  Next;
                  P1 := Parse_Expr;
                  if P1.Typ /= T_Str then
                     raise O2c_Error with "FDel needs a file path";
                  end if;
                  Expect (Lex.Tok_RParen, "')'");
                  Next;
                  Append_Body ("      O2c_FDel ("
                               & To_String (P1.Text) & ");");
               end;
            elsif To_String (Mod_Name) = "Files"
              and then Eq_No_Case (Head (1 .. H_Len), "FRENAME")
            then
               --  Refused in bytecode mode rather than silently emitting
               --  nothing: this branch appends to the Ada body and makes no
               --  O2c_BC call at all, so a bytecode program would compile,
               --  run, and quietly do nothing at all.
               if O2c_BC.Bytecode_Mode then
                  raise O2c_BC.Wrong_Construct with "bytecode backend: "
                    & "Files.FRename are not yet supported";
               end if;
               --  M44 FFI: rename within a volume (builtin Files only)
               declare
                  P1, P2 : Expr_Rec;
               begin
                  Next;
                  Expect (Lex.Tok_LParen, "'(' after FRename");
                  Next;
                  P1 := Parse_Expr;
                  if P1.Typ /= T_Str then
                     raise O2c_Error with "FRename needs a source path";
                  end if;
                  Expect (Lex.Tok_Comma, "','");
                  Next;
                  P2 := Parse_Expr;
                  if P2.Typ /= T_Str then
                     raise O2c_Error with "FRename needs a target path";
                  end if;
                  Expect (Lex.Tok_RParen, "')'");
                  Next;
                  Append_Body ("      O2c_FRename ("
                               & To_String (P1.Text) & ", "
                               & To_String (P2.Text) & ");");
               end;
            elsif Eq_No_Case (Head (1 .. H_Len), "INC")
              or else Eq_No_Case (Head (1 .. H_Len), "DEC")
            then
               --  predeclared INC/DEC (M25): INC(x [, n]) / DEC(x [, n])
               declare
                  Neg  : constant Boolean :=
                    Eq_No_Case (Head (1 .. H_Len), "DEC");
                  Id   : Natural := 0;
                  Nm   : String (1 .. 128);
                  N_Len : Natural;
               begin
                  Next;              --  past INC/DEC
                  if Cur.Kind = Lex.Tok_LParen then
                     Next;
                     if Cur.Kind /= Lex.Tok_Ident then
                        raise O2c_Error with "INC/DEC needs a variable "
                          & "(line " & Natural'Image (Cur.Line) & ")";
                     end if;
                     Id := Find (Cur.Text (1 .. Cur.Len));
                     N_Len := Cur.Len;
                     Nm (1 .. N_Len) := Cur.Text (1 .. Cur.Len);
                     Next;
                  else
                     Id := Find (Head (1 .. H_Len));
                     N_Len := H_Len;
                     Nm (1 .. N_Len) := Head (1 .. H_Len);
                  end if;
                  if Id = 0 or else Syms (Id).Kind /= S_Var
                    or else not (Syms (Id).Typ = T_Int
                                 or else Syms (Id).Typ = T_Long)
                  then
                     raise O2c_Error with "INC/DEC needs an INTEGER or "
                       & "LONGINT variable (line "
                       & Natural'Image (Cur.Line) & ")";
                  end if;
                  declare
                     Step : String := "1";
                  begin
                     if Cur.Kind = Lex.Tok_Comma then
                        Next;
                        declare
                           V : Expr_Rec := Parse_Expr;
                        begin
                           if V.Typ /= T_Int then
                              raise O2c_Error with "the INC/DEC step must "
                                & "be INTEGER";
                           end if;
                           if Syms (Id).Typ = T_Long
                             and then not V.Lit
                           then
                              raise O2c_Error with "INC/DEC on LONGINT "
                                & "takes plain literals only";
                           end if;
                           Step := To_String (V.Text);
                        end;
                     end if;
                     Append_Body ("      " & Nm (1 .. N_Len) & " := "
                                  & Nm (1 .. N_Len)
                                  & (if Neg then " - " else " + ")
                                  & Step & ";");
                  end;
                  if Cur.Kind = Lex.Tok_RParen then
                     Next;
                  end if;
               end;
            elsif Eq_No_Case (Head (1 .. H_Len), "NEW") then
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
                     if UTypes (D.UT).Ptr_Tgt = 0 then
                        raise O2c_Error with "cannot NEW an opaque POINTER "
                          & "here (M26)";
                     end if;
                     if O2c_BC.Bytecode_Mode then
                        --  The target record is N_F scalar slots, so the
                        --  descriptor's size is N_F * 8.  A designator
                        --  argument would intern a global named after the
                        --  Ada text, so it is refused.
                        if (for some Ch of NNm =>
                              Ch not in 'A' .. 'Z' | 'a' .. 'z'
                                        | '0' .. '9' | '_')
                        then
                           raise O2c_BC.Wrong_Construct with "bytecode "
                             & "backend: NEW of a pointer designator is not "
                             & "yet supported";
                        end if;
                        --  Parsing the argument pushed the pointer's old
                        --  value, which NEW never reads: the allocator's
                        --  result is what gets stored.  Left on the stack it
                        --  is one leaked slot per execution, which a loop
                        --  turns into a steady climb to the stack ceiling.
                        O2c_BC.Drop;
                        O2c_BC.Alloc_New
                          (Desc_For (UTypes (D.UT).Ptr_Tgt));
                        Bc_Store (NNm);
                     else
                        Append_Body ("      " & To_String (D.Text)
                                     & " := new "
                                     & Ada_Last (To_String
                                       (UTypes (UTypes (D.UT).Ptr_Tgt).Name))
                                     & ";");
                     end if;
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
                           --  The parsed form is kept as well as the text:
                           --  a bytecode emission needs the operand's type
                           --  and name, which the Ada text alone cannot give.
                           Arg_R : array (1 .. Max_Params) of Expr_Rec;
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
                                 Arg_R (N_A) := A;
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
                           Call := Call & Ada_Id (MNm) & "."
                             & Ada_Id (To_String (MName)) & " (";
                           for I in 1 .. N_A loop
                              if I > 1 then
                                 Call := Call & ", ";
                              end if;
                              Call := Call & Args (I);
                           end loop;
                           Call := Call & ");";
                           if O2c_BC.Bytecode_Mode
                             and then Is_FFI_Mod (MNm)
                           then
                              --  The FFI surface takes ADDRESSES: these are
                              --  written in terms of out parameters, so the
                              --  call site pushes where the results go and
                              --  the native writes through.  Only the one
                              --  native that exists is wired; the rest still
                              --  refuse rather than appending Ada text that
                              --  bytecode would discard.
                              --  ToInt and ToReal take the same three
                              --  arguments in the same order - string, the
                              --  out slot, the status - and differ only in
                              --  whether that slot holds an INTEGER or a
                              --  REAL, which the native knows and the call
                              --  site does not need to.
                              if Eq_No_Case (MNm, "Convert")
                                and then (Eq_No_Case
                                            (To_String (MName), "ToInt")
                                          or else Eq_No_Case
                                            (To_String (MName), "ToReal"))
                                and then N_A = 3
                              then
                                 declare
                                    SNm : constant String :=
                                      To_String (Arg_R (1).Text);
                                    SId : constant Natural := Find (SNm);
                                 begin
                                    if SId = 0
                                      or else Syms (SId).UT = 0
                                    then
                                       raise O2c_BC.Wrong_Construct with
                                         "bytecode backend: Convert.ToInt "
                                         & "needs a declared ARRAY OF CHAR "
                                         & "variable";
                                    end if;
                                    O2c_BC.Load_Addr_G
                                      (O2c_BC.Global_Array
                                         (Ada_Id (SNm),
                                          Total_Slots (Syms (SId).UT)));
                                 end;
                                 O2c_BC.Load_Addr_G
                                   (O2c_BC.Global
                                      (Ada_Id (To_String (Arg_R (2).Text))));
                                 O2c_BC.Load_Addr_G
                                   (O2c_BC.Global
                                      (Ada_Id (To_String (Arg_R (3).Text))));
                                 --  Foreign entries 2 and 4: ToInt and
                                 --  ToReal, native ids 6 and 8.
                                 O2c_BC.Native_Call
                                   ((if Eq_No_Case (To_String (MName),
                                                    "ToInt")
                                     then 6 else 8), 3);
                              elsif Eq_No_Case (MNm, "Convert")
                                and then Eq_No_Case
                                  (To_String (MName), "FromInt")
                                and then N_A = 2
                              then
                                 --  Value first, then the buffer address:
                                 --  FromInt reads its argument and writes its
                                 --  digits, where ToInt only writes.
                                 Bc_Load
                                   (Ada_Id (To_String (Arg_R (1).Text)));
                                 declare
                                    SNm : constant String :=
                                      To_String (Arg_R (2).Text);
                                    SId : constant Natural := Find (SNm);
                                 begin
                                    if SId = 0
                                      or else Syms (SId).UT = 0
                                    then
                                       raise O2c_BC.Wrong_Construct with
                                         "bytecode backend: Convert.FromInt "
                                         & "needs a declared ARRAY OF CHAR "
                                         & "variable";
                                    end if;
                                    O2c_BC.Load_Addr_G
                                      (O2c_BC.Global_Array
                                         (Ada_Id (SNm),
                                          Total_Slots (Syms (SId).UT)));
                                 end;
                                 --  Native id 7: the third foreign entry.
                                 O2c_BC.Native_Call (7, 2);
                              else
                                 raise O2c_BC.Wrong_Construct with
                                   "bytecode backend: " & MNm & "."
                                   & To_String (MName)
                                   & " is an FFI primitive and is not yet "
                                   & "supported";
                              end if;
                           end if;
                           Append_Body ("      " & To_String (Call));
                        end;
                     else
                        if Xs (XI).Params /= 0 then
                           raise O2c_Error with "'" & MNm & "."
                             & To_String (MName) & "' needs arguments";
                        end if;
                        if O2c_BC.Bytecode_Mode
                          and then Is_FFI_Mod (MNm)
                        then
                           raise O2c_BC.Wrong_Construct with
                             "bytecode backend: " & MNm & "."
                             & To_String (MName)
                             & " is an FFI primitive and is not yet supported";
                        end if;
                        Append_Body ("      " & Ada_Id (MNm) & "."
                                     & Ada_Id (To_String (MName)) & ";");
                     end if;
                  elsif Xs (XI).Kind = S_Var
                    and then Length (Xs (XI).VT_Nm) > 0
                  then
                     --  M20f/M22: exported RECORD VARIABLE: assign a
                     --  field through the designator chain, or the whole
                     --  record from a same-typed variable (local or an
                     --  exported module VARIABLE of the same type).
                     if Cur.Kind /= Lex.Tok_Dot
                       and then Cur.Kind /= Lex.Tok_Assign
                     then
                        raise O2c_Error with "'" & MNm & "."
                          & To_String (MName)
                          & "' is a RECORD VARIABLE; select a field with "
                          & "'.' or assign the whole record (M22)";
                     end if;
                     declare
                        Q : constant String := To_String (Xs (XI).VT_Nm);
                        U : constant Natural :=
                          Import_Type (Q_Owner (Q), Q_Mem (Q));
                     begin
                        if Cur.Kind = Lex.Tok_Assign then
                           --  whole-record assignment (M22)
                           declare
                              Rhs : Unbounded_String;
                           begin
                              Next;
                              if Cur.Kind = Lex.Tok_Ident then
                                 declare
                                    RId : constant Natural :=
                                      Find (Cur.Text (1 .. Cur.Len));
                                 begin
                                    if RId /= 0 and then
                                      Syms (RId).Kind = S_Var
                                      and then Syms (RId).UT = U
                                    then
                                       Rhs := To_Unbounded_String
                                         (Cur.Text (1 .. Cur.Len));
                                       Next;
                                    end if;
                                 end;
                              end if;
                              if Rhs = "" and then Cur.Kind = Lex.Tok_Ident
                                and then Imported_Mod
                                  (Cur.Text (1 .. Cur.Len))
                              then
                                 declare
                                    MN2 : constant String :=
                                      Cur.Text (1 .. Cur.Len);
                                 begin
                                    Next;
                                    if Cur.Kind = Lex.Tok_Dot then
                                       Next;
                                       Expect (Lex.Tok_Ident,
                                               "a module variable");
                                       declare
                                          XI2 : constant Natural :=
                                            Find_X
                                              (MN2,
                                               Cur.Text (1 .. Cur.Len));
                                       begin
                                          if XI2 /= 0
                                            and then Xs (XI2).Kind = S_Var
                                            and then
                                              To_String (Xs (XI2).VT_Nm)
                                              = To_String (Xs (XI).VT_Nm)
                                          then
                                             Rhs := To_Unbounded_String
                                               (Ada_Id (MN2) & "."
                                                & Ada_Id
                                                    (Cur.Text (1 .. Cur.Len)));
                                          end if;
                                          Next;
                                       end;
                                    end if;
                                 end;
                              end if;
                              if Length (Rhs) = 0 then
                                 raise O2c_Error with "whole-record "
                                   & "assignment to '" & MNm & "."
                                   & To_String (MName)
                                   & "' needs a variable of the same "
                                   & "record type (M22)";
                              end if;
                              Append_Body ("      " & Ada_Id (MNm) & "."
                                           & Ada_Id (To_String (MName))
                                           & " := "
                                           & To_String (Rhs) & ";");
                           end;
                        else
                           declare
                              D : Desig := Parse_Rec_Ptr_Chain
                                (Ada_Id (MNm) & "."
                                 & Ada_Id (To_String (MName)), U);
                           begin
                              Expect (Lex.Tok_Assign, "':='");
                              Next;
                              if D.K = D_Index then
                                 --  [base, index]: evaluate the value, store it.
                                 declare
                                    V : Expr_Rec := Parse_Expr;
                                 begin
                                    if D.Sc = T_Char or else D.Sc = T_Bool then
                                       O2c_BC.Bin (O2c_BC.Store_Idx_B);
                                    else
                                       O2c_BC.Bin (O2c_BC.Store_Idx_I);
                                    end if;
                                 end;
                              elsif D.K = D_Field then
                                 --  [record]: evaluate the value, store it in the field.
                                 declare
                                    V : Expr_Rec := Parse_Expr;
                                 begin
                                    if D.Ptr_Field then O2c_BC.Store_Fld_P (D.Off);
                                     elsif D.Sc = T_Real or else D.Sc = T_LReal then
                                        O2c_BC.Store_Fld_R (D.Off);
                                     else O2c_BC.Store_Fld (D.Off);
                                     end if;
                                 end;
                              elsif D.K = D_Scalar then
                                 if D.Sc = T_Char
                                   and then Cur.Kind = Lex.Tok_String
                                   and then Cur.Len = 1
                                 then
                                    Append_Body ("      "
                                                 & To_String (D.Text)
                                                 & " := '"
                                                 & Cur.Text (1 .. 1) & "';");
                                    Next;
                                 else
                                    declare
                                       V : Expr_Rec := Parse_Expr;
                                    begin
                                       if V.Typ /= D.Sc
                                         or else V.Typ = T_Str
                                       then
                                          --  Naming both sides is worth the
                                          --  words: a mistyped designator
                                          --  is otherwise a puzzle.
                                          raise O2c_Error with
                                            "type mismatch assigning "
                                            & To_String (D.Text)
                                            & " (value is "
                                            & EType'Image (V.Typ)
                                            & ", target is "
                                            & EType'Image (D.Sc) & ")";
                                       end if;
                                       Append_Body ("      "
                                                    & To_String (D.Text)
                                                    & " := "
                                                    & To_String (V.Text)
                                                    & ";");
                                    end;
                                 end if;
                              elsif D.K = D_Ptr then
                                 raise O2c_Error with "cannot assign a "
                                   & "POINTER field of a module VARIABLE "
                                   & "here (M20f)";
                              else
                                 raise O2c_Error with "cannot assign a "
                                   & "whole char-array field here (M20f)";
                              end if;
                           end;
                        end if;
                     end;
                  elsif Xs (XI).Kind = S_Var
                    and then Length (Xs (XI).VT_Nm) = 0
                  then
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
                              Append_Body ("      " & Ada_Id (MNm) & "."
                                           & Ada_Id (To_String (MName))
                                           & " := Float ("
                                           & To_String (V.Text) & ");");
                           elsif V.Typ = T_Real then
                              Append_Body ("      " & Ada_Id (MNm) & "."
                                           & Ada_Id (To_String (MName))
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
                           Append_Body ("      " & Ada_Id (MNm) & "."
                                        & Ada_Id (To_String (MName))
                                        & " := "
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
                              if BI = 0 and then
                                XM_Chain (Urec, T1.Text (1 .. T1.Len)) /= 0
                              then
                                 --  M20c/M23: method from an imported
                                 --  record (or a local extension of one):
                                 --  call the exported dispatcher
                                 declare
                                    XMI  : constant Natural :=
                                      XM_Chain (Urec,
                                                T1.Text (1 .. T1.Len));
                                    Ownr : constant String :=
                                      To_String (XMs (XMI).Owner);
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
                                          declare
                                             SI : constant Natural :=
                                               Sh_Find (Ownr, RNm, DNm);
                                          begin
                                             if SI /= 0 then
                                                --  M29: widened-pointer
                                                --  dispatch through the
                                                --  override module's shadow
                                                Call := Call
                                                  & To_String (Shs (SI).Owner)
                                                  & "." & DNm
                                                  & "_Any_Disp_O2c_"
                                                  & To_String (Shs (SI).BRec)
                                                  & " (" & Rtxt;
                                             else
                                                Call := Call & Ownr & "."
                                                  & DNm
                                                  & "_Disp_O2c_" & RNm
                                                  & " (" & Rtxt;
                                             end if;
                                          end;
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
                        if D.K = D_Index then
                           --  [base, index]: evaluate the value, store it.
                           declare
                              V : Expr_Rec := Parse_Expr;
                           begin
                              if D.Sc = T_Char or else D.Sc = T_Bool then
                                 O2c_BC.Bin (O2c_BC.Store_Idx_B);
                              else
                                 O2c_BC.Bin (O2c_BC.Store_Idx_I);
                              end if;
                           end;
                        elsif D.K = D_Field then
                           --  [record]: evaluate the value, store it in the field.
                           declare
                              V : Expr_Rec := Parse_Expr;
                           begin
                              if D.Ptr_Field then O2c_BC.Store_Fld_P (D.Off);
                               elsif D.Sc = T_Real or else D.Sc = T_LReal then
                                  O2c_BC.Store_Fld_R (D.Off);
                               else O2c_BC.Store_Fld (D.Off);
                               end if;
                           end;
                        elsif D.K = D_Scalar then
                           if not O2c_BC.Bytecode_Mode
                             and then (D.Sc = T_Char and then Cur.Kind = Lex.Tok_String)
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
                                 if D.Sc = T_Real and then V.Typ = T_Int then
                                    V.Text := To_Unbounded_String
                                      ("Float (" & To_String (V.Text) & ")");
                                    V.Typ := T_Real;
                                 elsif D.Sc = T_LReal
                                   and then (V.Typ = T_Int
                                             or else V.Typ = T_Real)
                                 then
                                    if V.Typ = T_Real and then not V.Lit then
                                       raise O2c_Error with "type mismatch "
                                         & "assigning "
                                         & To_String (D.Text);
                                    end if;
                                    V.Text := To_Unbounded_String
                                      ("Long_Float (" & To_String (V.Text)
                                       & ")");
                                    V.Typ := T_LReal;
                                 elsif D.Sc = T_Long and then V.Typ = T_Int then
                                    if not V.Lit then
                                       raise O2c_Error with "type mismatch "
                                         & "assigning "
                                         & To_String (D.Text);
                                    end if;
                                    V.Typ := T_Long;
                                 end if;
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
                     if Cur.Kind = Lex.Tok_String and then Cur.Len = 1
                       and then not O2c_BC.Bytecode_Mode
                     then
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
                     if O2c_BC.Bytecode_Mode then
                        O2c_BC.Load_Addr_G
                          (O2c_BC.Global_Array
                             (Ada_Id (Head (1 .. H_Len)), Total_Slots (U)));
                        O2c_BC.Push_Str (Cur.Text (1 .. Cur.Len));
                        O2c_BC.Bin (O2c_BC.Copy_Str);
                     elsif Cur.Len = N then
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
                  elsif UTypes (U).Is_Rec
                    and then Cur.Kind = Lex.Tok_LBrace
                  then
                     --  M35/M37: record aggregate { f = value, ... };
                     --  components default, extension types emit nested
                     --  Ada extension aggregates over the whole chain.
                     Next;   --  past '{'
                     declare
                        Chain : array (1 .. 8) of Natural := (others => 0);
                        NCh   : Natural := 0;
                        Used  : array (1 .. 8, 1 .. 16) of Boolean :=
                          (others => (others => False));
                        Val   : array (1 .. 8, 1 .. 16) of Unbounded_String :=
                          (others => (others => <>));
                        Tmp   : Natural := U;
                     begin
                        while Tmp /= 0 loop
                           NCh := NCh + 1;
                           if NCh > Chain'Last then
                              raise O2c_Error with "record extension chain "
                                & "too deep for an aggregate (M37)";
                           end if;
                           Chain (NCh) := Tmp;
                           Tmp := UTypes (Tmp).Parent;
                        end loop;
                        loop
                           exit when Cur.Kind = Lex.Tok_RBrace;
                           if Cur.Kind /= Lex.Tok_Ident then
                              raise O2c_Error with "a field name expected "
                                & "in the record aggregate";
                           end if;
                           declare
                              FNm  : constant String := Cur.Text (1 .. Cur.Len);
                              NI   : Natural := 0;
                              FI   : Natural := 0;
                              FTyp : EType := T_Int;
                           begin
                              for C in 1 .. NCh loop
                                 for F in 1 .. UTypes (Chain (C)).N_F loop
                                    if To_String (UTypes (Chain (C)).F (F).Name)
                                      = FNm
                                    then
                                       NI := C;
                                       FI := F;
                                       FTyp := UTypes (Chain (C)).F (F).Typ;
                                    end if;
                                 end loop;
                              end loop;
                              if NI = 0 then
                                 raise O2c_Error with "no field '" & FNm
                                   & "' in " & To_String (UTypes (U).Name);
                              end if;
                              if UTypes (Chain (NI)).Imported
                                and then not UTypes (Chain (NI)).F (FI).ExpF
                              then
                                 raise O2c_Error with "field '" & FNm
                                   & "' is not exported (M37)";
                              end if;
                              if UTypes (Chain (NI)).F (FI).UT /= 0 then
                                 raise O2c_Error with "record aggregate "
                                   & "fields must be scalar (M37; '"
                                   & FNm & "')";
                              end if;
                              if Used (NI, FI) then
                                 raise O2c_Error with "field '" & FNm
                                   & "' given twice in the aggregate";
                              end if;
                              Used (NI, FI) := True;
                              Next;               --  past the field name
                              Expect (Lex.Tok_Equal, "'='");
                              Next;
                              declare
                                 V : Expr_Rec := Parse_Expr;
                              begin
                                 if FTyp = T_Real then
                                    if V.Typ = T_Int then
                                       V.Text := To_Unbounded_String
                                         ("Float (" & To_String (V.Text)
                                          & ")");
                                    elsif V.Typ /= T_Real then
                                       raise O2c_Error with "field '" & FNm
                                         & "' expects a REAL value";
                                    end if;
                                 elsif V.Typ /= FTyp
                                   and then not (FTyp = T_Long
                                                 and then V.Typ = T_Int
                                                 and then V.Lit)
                                 then
                                    raise O2c_Error with "field '" & FNm
                                      & "' has the wrong type";
                                 end if;
                                 Val (NI, FI) := V.Text;
                              end;
                           end;
                           exit when Cur.Kind /= Lex.Tok_Comma;
                           Next;
                        end loop;
                        Expect (Lex.Tok_RBrace, "'}'");
                        Next;
                        declare
                           function Build (Nd : Natural) return String is
                              Res : Unbounded_String;
                              NI  : Natural := 0;
                           begin
                              for C in 1 .. NCh loop
                                 if Chain (C) = Nd then
                                    NI := C;
                                 end if;
                              end loop;
                              for F in 1 .. UTypes (Nd).N_F loop
                                 if UTypes (Nd).F (F).UT /= 0 then
                                    raise O2c_Error with "record aggregate "
                                      & "needs scalar fields only (M37)";
                                 end if;
                                 if F > 1 then
                                    Res := Res & ", ";
                                 end if;
                                 Res := Res & To_String (UTypes (Nd).F (F).Name)
                                   & " => "
                                   & (if Used (NI, F)
                                      then To_String (Val (NI, F))
                                      else Scalar_Init
                                        (UTypes (Nd).F (F).Typ));
                              end loop;
                              if UTypes (Nd).Parent /= 0 then
                                 return To_String (UTypes (Nd).Name) & "'("
                                   & Build (UTypes (Nd).Parent)
                                   & " with " & To_String (Res) & ")";
                              end if;
                              return To_String (UTypes (Nd).Name) & "'("
                                & To_String (Res) & ")";
                           end Build;
                        begin
                           Append_Body ("      " & Head (1 .. H_Len)
                                        & " := " & Build (U) & ";");
                        end;
                     end;
                  elsif not UTypes (U).Is_Rec
                    and then Cur.Kind = Lex.Tok_LBrace
                  then
                     --  M36: numeric fixed-array aggregate { e1, e2, .. }
                     Next;
                     declare
                        A : Unbounded_String;
                        N : Natural := 0;
                     begin
                        loop
                           exit when Cur.Kind = Lex.Tok_RBrace;
                           N := N + 1;
                           if N > UTypes (U).Arr_Len then
                              raise O2c_Error with "array aggregate has "
                                & "too many elements (line "
                                & Natural'Image (Cur.Line) & ")";
                           end if;
                           declare
                              V : Expr_Rec := Parse_Expr;
                           begin
                              if UTypes (U).Elem = T_Char
                                and then V.Typ = T_Str
                              then
                                 --  single-character string literal
                                 declare
                                    T : constant String :=
                                      To_String (V.Text);
                                 begin
                                    if T'Length = 3 and then
                                      T (T'First) = '"'
                                      and then T (T'Last) = '"'
                                    then
                                       V.Typ := T_Char;
                                       V.Text := To_Unbounded_String
                                         ("'" & T (T'First + 1) & "'");
                                    end if;
                                 end;
                              end if;
                              if V.Typ /= UTypes (U).Elem then
                                 raise O2c_Error with "array element type "
                                   & "mismatch (line "
                                   & Natural'Image (Cur.Line) & ")";
                              end if;
                              if N > 1 then
                                 A := A & ", ";
                              end if;
                              A := A & To_String (V.Text);
                           end;
                           exit when Cur.Kind /= Lex.Tok_Comma;
                           Next;
                        end loop;
                        Expect (Lex.Tok_RBrace, "'}'");
                        Next;
                        if N /= UTypes (U).Arr_Len then
                           raise O2c_Error with "array aggregate needs "
                             & Integer'Image (UTypes (U).Arr_Len)
                             & " elements";
                        end if;
                        Append_Body ("      " & Head (1 .. H_Len)
                                     & " := (" & To_String (A) & ");");
                     end;
                  else
                     --  M28: whole copy from a same-typed local variable
                     --  or an exported module RECORD VARIABLE
                     declare
                        Rhs : Unbounded_String;
                     begin
                        if Cur.Kind = Lex.Tok_Ident then
                           declare
                              R : constant Natural :=
                                Find (Cur.Text (1 .. Cur.Len));
                           begin
                              if R /= 0 and then Syms (R).Kind = S_Var
                                and then Syms (R).UT = Syms (Idx).UT
                              then
                                 Rhs := To_Unbounded_String
                                   (Cur.Text (1 .. Cur.Len));
                                 Next;
                              end if;
                           end;
                        end if;
                        if Length (Rhs) = 0 and then Cur.Kind = Lex.Tok_Ident
                          and then Imported_Mod (Cur.Text (1 .. Cur.Len))
                        then
                           declare
                              MN2 : constant String :=
                                Cur.Text (1 .. Cur.Len);
                           begin
                              Next;
                              if Cur.Kind = Lex.Tok_Dot then
                                 Next;
                                 Expect (Lex.Tok_Ident,
                                         "a module variable");
                                 declare
                                    XI2 : constant Natural :=
                                      Find_X (MN2,
                                              Cur.Text (1 .. Cur.Len));
                                 begin
                                    if XI2 /= 0
                                      and then Xs (XI2).Kind = S_Var
                                      and then Length (Xs (XI2).VT_Nm) > 0
                                    then
                                       declare
                                          Q  : constant String :=
                                            To_String (Xs (XI2).VT_Nm);
                                          TY : constant Natural :=
                                            Import_Type (Q_Owner (Q),
                                                         Q_Mem (Q));
                                       begin
                                          if TY = Syms (Idx).UT then
                                             Rhs := To_Unbounded_String
                                               (Ada_Id (MN2) & "."
                                                & Ada_Id
                                                    (Cur.Text (1 .. Cur.Len)));
                                          end if;
                                       end;
                                    end if;
                                    Next;
                                 end;
                              end if;
                           end;
                        end if;
                        if Length (Rhs) = 0 then
                           --  A procedure value: the right-hand side names a
                           --  procedure rather than reading a variable, so
                           --  the value is its id.  Only accepted when the
                           --  target is PROCEDURE-typed - nothing else takes
                           --  a bare name here.
                           declare
                              LS : constant Natural :=
                                Find (Head (1 .. H_Len));
                              RS : constant Natural :=
                                Find (Cur.Text (1 .. Cur.Len));
                           begin
                              if O2c_BC.Bytecode_Mode
                                and then LS > 0 and then RS > 0
                                and then Syms (LS).UT > 0
                                and then UTypes (Syms (LS).UT).Is_Proc
                                and then Syms (RS).Kind = S_Proc
                                and then Syms (RS).Params /= 0
                              then
                                 raise O2c_Error with "'"
                                   & Cur.Text (1 .. Cur.Len)
                                   & "' takes arguments, so it cannot be a "
                                   & "PROCEDURE value (a procedure type is "
                                   & "parameterless)";
                              elsif O2c_BC.Bytecode_Mode
                                and then LS > 0 and then RS > 0
                                and then Syms (LS).UT > 0
                                and then UTypes (Syms (LS).UT).Is_Proc
                                and then Syms (RS).Kind = S_Proc
                                and then not Syms (RS).Ret
                              then
                                 O2c_BC.Push_BC_Proc (Syms (RS).Bc_Proc);
                                 --  Store it: pushing alone leaves the
                                 --  variable holding whatever it held, which
                                 --  for a fresh one is the zeroed slot.
                                 Bc_Store (Head (1 .. H_Len));
                                 Next;
                              else
                                 raise O2c_Error with "'"
                                   & Cur.Text (1 .. Cur.Len)
                                   & "' is not a same-typed variable "
                                   & "(copy of " & Head (1 .. H_Len) & ")";
                              end if;
                           end;
                        end if;
                        Append_Body ("      " & Head (1 .. H_Len) & " := "
                                     & To_String (Rhs) & ";");
                     end;
                  end if;
               end;
            elsif Cur.Kind = Lex.Tok_Dot
              and then Head (1 .. H_Len) = "Threads"
            then
               --  Threads.Start (p): start a thread on a procedure value, so
               --  the argument may be a name or a PROCEDURE-typed variable -
               --  the same value that b() calls through.  A sibling branch of
               --  the Out case rather than a case inside it, because what
               --  follows is Out's own argument handling and a Threads call
               --  must not fall through into it.
               Next;                        --  past '.'
               Expect (Lex.Tok_Ident, "a member name after '.'");
               if not O2c_BC.Bytecode_Mode then
                  raise O2c_Error with "Threads needs the bytecode backend "
                    & "(the Ada backend has no threads)";
               end if;
               declare
                  Member : constant String := Cur.Text (1 .. Cur.Len);
               begin
                  if Member = "Start" then
                     Next;                     --  past Start -> '('
                     Expect (Lex.Tok_LParen, "'(' after Threads.Start");
                     Next;
                     Expect (Lex.Tok_Ident, "a procedure or a "
                             & "PROCEDURE-typed variable");
                     declare
                        Arg : constant String := Cur.Text (1 .. Cur.Len);
                        AI  : constant Natural := Find (Arg);
                     begin
                        Next;                  --  past the argument
                        Expect (Lex.Tok_RParen, "')' after Threads.Start");
                        Next;
                        if AI > 0 and then Syms (AI).Kind = S_Proc
                          and then Syms (AI).Params /= 0
                        then
                           raise O2c_Error with "Threads.Start needs a "
                             & "procedure that takes no arguments ('" & Arg
                             & "' takes some)";
                        end if;
                        if AI > 0
                          and then Syms (AI).Kind = S_Proc
                          and then not Syms (AI).Ret
                          and then Syms (AI).Bc_Proc /= 0
                        then
                           O2c_BC.Push_BC_Proc (Syms (AI).Bc_Proc);
                        elsif AI > 0 and then Syms (AI).UT > 0
                          and then UTypes (Syms (AI).UT).Is_Proc
                        then
                           Bc_Load (Arg);
                        else
                           raise O2c_Error with "Threads.Start needs a "
                             & "parameterless procedure or a PROCEDURE-typed "
                             & "variable (found '" & Arg & "')";
                        end if;
                        O2c_BC.Spawn;
                        --  A statement discards the handle.  Capturing it
                        --  needs Start as an expression, which is not there
                        --  yet - so leaving it on the stack would silently
                        --  unbalance every program that starts a thread.
                        O2c_BC.Drop;
                     end;
                  elsif Member = "Join" then
                     --  Threads.Join (h): wait for a thread.  The handle is
                     --  whatever the program kept from the spawn, so it is
                     --  loaded as an ordinary value.
                     Next;                     --  past Join -> '('
                     Expect (Lex.Tok_LParen, "'(' after Threads.Join");
                     Next;
                     Expect (Lex.Tok_Ident, "a thread handle");
                     declare
                        Arg : constant String := Cur.Text (1 .. Cur.Len);
                     begin
                        Next;                  --  past the argument
                        Expect (Lex.Tok_RParen, "')' after Threads.Join");
                        Next;
                        Bc_Load (Arg);
                        O2c_BC.Join;
                     end;
                  elsif Member = "Yield" then
                     --  Give up the rest of the quantum.  Worth having
                     --  because it costs nothing at a point the program knows
                     --  is a good one, rather than wherever the budget runs
                     --  out - and a yield that never returns buys nothing.
                     Next;                     --  past Yield
                     Expect (Lex.Tok_LParen,
                             "'(' after Threads.Yield (list it explicitly)");
                     Next;
                     Expect (Lex.Tok_RParen, "')' after Threads.Yield");
                     Next;
                     O2c_BC.Thread_Yield;
                  elsif Member = "Init" or else Member = "Lock"
                    or else Member = "Unlock"
                  then
                     --  A mutex is an INTEGER variable the program owns, and
                     --  the VM needs its globals slot.  A local would have no
                     --  stable slot to name, so it is refused rather than
                     --  silently becoming a new global of its own.
                     Next;                     --  past the member -> '('
                     Expect (Lex.Tok_LParen, "'(' after Threads." & Member);
                     Next;
                     Expect (Lex.Tok_Ident, "a mutex variable");
                     declare
                        Arg : constant String := Cur.Text (1 .. Cur.Len);
                     begin
                        if O2c_BC.Local_Slot (Ada_Id (Arg)) >= 0 then
                           raise O2c_Error with "a mutex must be a "
                             & "module-level variable, not a local";
                        end if;
                        Next;                  --  past the argument
                        Expect (Lex.Tok_RParen,
                                "')' after Threads." & Member);
                        Next;
                        if Member = "Init" then
                           --  Globals start zeroed, so this is only needed to
                           --  put a used mutex back to free.
                           O2c_BC.Push_Int (0);
                           O2c_BC.Store (O2c_BC.Global (Ada_Id (Arg)));
                        elsif Member = "Lock" then
                           O2c_BC.Mutex_Lock (O2c_BC.Global (Ada_Id (Arg)));
                        else
                           O2c_BC.Mutex_Unlock
                             (O2c_BC.Global (Ada_Id (Arg)));
                        end if;
                     end;
                  else
                     raise O2c_Error with "Threads provides Start, Join, "
                       & "Yield, Init, Lock and Unlock (found '" & Member
                       & "')";
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
                  Had_Width : Boolean := False;
                  Str_Looped : Boolean := False;
               begin
                  if Head (1 .. H_Len) /= "Out" then
                     raise O2c_Error with "M3 calls only module Out (found '"
                       & Head (1 .. H_Len) & "." & Member & "')";
                  end if;
                  Used_Console := True;
                  Next;
                  if Member = "Ln" then
                     if O2c_BC.Bytecode_Mode then
                        O2c_BC.Native_Call (2, 0);
                     end if;
                     Append_Body ("      Aegir_User.Console.Put_Line ("""");");
                  elsif Member = "String" or else Member = "Int"
                    or else Member = "Char" or else Member = "Real"
                    or else Member = "LongReal"
                  then
                     Expect (Lex.Tok_LParen, "'(' after Out." & Member);
                     Next;
                     if Member = "String" then
                        declare
                           A : Expr_Rec := Parse_Expr;
                        begin
                           if A.Typ = T_Char then
                              --  A char is a one-character string here.
                              --  The factor pushed its code, so replace it
                              --  with the string; only a literal can be
                              --  folded, since a variable's text is its
                              --  name, not its value.
                              if not A.Lit then
                                 raise O2c_Error with
                                   "Out.String needs a string, and a char "
                                   & "variable cannot become one yet";
                              end if;
                              declare
                                 Ch : constant String := To_String (A.Text);
                              begin
                                 if O2c_BC.Bytecode_Mode then
                                    O2c_BC.Discard;
                                    O2c_BC.Push_Str (Ch (2 .. 2));
                                 end if;
                                 M := To_Unbounded_String
                                   (Ada_String_Literal (Ch (2 .. 2)));
                              end;
                              CArg := False;
                           elsif A.Typ /= T_Str then
                              raise O2c_Error
                                with "Out.String needs a string argument";
                           else
                              M := A.Text;
                              CArg := A.CStr;
                              if O2c_BC.Bytecode_Mode
                                and then Find (To_String (A.Text)) > 0
                              then
                                 declare
                                    ASym : constant Natural :=
                                      Find (To_String (A.Text));
                                 begin
                                    if Syms (ASym).UT > 0
                                      and then UTypes (Syms (ASym).UT).Elem
                                        = T_Char
                                    then
                                       declare
                                          AU    : constant Natural :=
                                            Syms (ASym).UT;
                                          N     : constant Integer :=
                                            UTypes (AU).Arr_Len;
                                          I_Sl  : constant Natural :=
                                            O2c_BC.Local ("o2c_str_i");
                                          V_Sl  : constant Natural :=
                                            O2c_BC.Local ("o2c_str_v");
                                          L_Top : constant Natural :=
                                            New_Bc_Label;
                                          L_End : constant Natural :=
                                            New_Bc_Label;
                                          L_Bdy : constant Natural :=
                                            New_Bc_Label;
                                       begin
                                          --  The chain pushed the array's
                                          --  address; this loop derives its
                                          --  own, so drop that one.
                                          O2c_BC.Discard;
                                          O2c_BC.Push_Int (0);
                                          O2c_BC.Store_Local (I_Sl);
                                          O2c_BC.Mark (L_Top);
                                          O2c_BC.Load_Local (I_Sl);
                                          O2c_BC.Push_Int (N);
                                          O2c_BC.Bin (O2c_BC.Lt);
                                          O2c_BC.Jump (O2c_BC.Jnz, L_Bdy);
                                          O2c_BC.Jump (O2c_BC.Jmp, L_End);
                                          O2c_BC.Mark (L_Bdy);
                                          O2c_BC.Load_Addr_G
                                            (O2c_BC.Global_Array
                                               (Ada_Id (To_String (A.Text)),
                                                Total_Slots (AU)));
                                          O2c_BC.Load_Local (I_Sl);
                                          O2c_BC.Bin (O2c_BC.Load_Idx_B);
                                          O2c_BC.Store_Local (V_Sl);
                                          O2c_BC.Load_Local (V_Sl);
                                          O2c_BC.Push_Int (0);
                                          O2c_BC.Bin (O2c_BC.Eq);
                                          O2c_BC.Jump (O2c_BC.Jnz, L_End);
                                          O2c_BC.Load_Local (V_Sl);
                                          O2c_BC.Native_Call (4, 1);
                                          O2c_BC.Load_Local (I_Sl);
                                          O2c_BC.Push_Int (1);
                                          O2c_BC.Bin (O2c_BC.Add);
                                          O2c_BC.Store_Local (I_Sl);
                                          O2c_BC.Jump (O2c_BC.Jmp, L_Top);
                                          O2c_BC.Mark (L_End);
                                          --  The member dispatch below runs
                                          --  separately from this block and
                                          --  would emit the pool-string
                                          --  native too, on a stack this
                                          --  loop has already emptied.
                                          Str_Looped := True;
                                       end;
                                    end if;
                                 end;
                              end if;
                           end if;
                        end;
                     elsif Member = "Char" then
                        declare
                           A : Expr_Rec := Parse_Expr;
                        begin
                           if A.Typ /= T_Char then
                              raise O2c_Error
                                with "Out.Char needs a CHAR argument";
                           end if;
                           M := A.Text;
                           CArg := False;
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
                     elsif Member = "LongReal" then
                        --  Out.LongReal (M47)
                        declare
                           A : Expr_Rec := Parse_Expr;
                        begin
                           if A.Typ = T_LReal then
                              M := A.Text;
                           elsif A.Typ = T_Int
                             or else (A.Typ = T_Real and then A.Lit)
                           then
                              M := To_Unbounded_String
                                ("Long_Float (" & To_String (A.Text) & ")");
                           else
                              raise O2c_Error
                                with "Out.LongReal needs a LONGREAL argument";
                           end if;
                           Used_LReal := True;
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
                        Had_Width := True;
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
                     if O2c_BC.Bytecode_Mode then
                        if Member = "Int" then
                           if not Had_Width then
                              O2c_BC.Push_Int (0);   --  omitted width: 0
                           end if;
                           O2c_BC.Native_Call (0, 2);
                        elsif Member = "String" then
                           if not Str_Looped then
                              O2c_BC.Native_Call (1, 1);
                           end if;
                        elsif Member = "Real" or else Member = "LongReal"
                        then
                           --  REAL and LONGREAL share a slot and the printing
                           --  native; only the Ada formatting differs.  The
                           --  optional width is accepted and unused, as it is
                           --  in O2c_Put_Real.
                           if not Had_Width then
                              O2c_BC.Push_Int (0);
                           end if;
                           O2c_BC.Native_Call (3, 2);
                        elsif Member = "Char" then
                           --  The factor already pushed the character's
                           --  code and the native takes one argument, so
                           --  there is nothing to convert here.
                           O2c_BC.Native_Call (4, 1);
                        else
                           raise O2c_BC.Wrong_Construct with
                             "bytecode backend: Out." & Member
                             & " is not yet supported";
                        end if;
                     end if;
                     if Member = "String" then
                        if CArg then
                           Used_CStr := True;
                           Append_Body ("      O2c_Put_CStr (" & To_String (M)
                                        & ");");
                        else
                           Append_Body ("      Aegir_User.Console.Put ("
                                        & To_String (M) & ");");
                        end if;
                     elsif Member = "Char" then
                        --  Ada prints a one-character string: Console.Put
                        --  already takes one, so no runtime helper is needed
                        --  and the RTS is untouched.
                        Append_Body ("      Aegir_User.Console.Put "
                                     & "(String'(1 => " & To_String (M)
                                     & "));");
                     elsif Member = "Int" then
                        Append_Body ("      O2c_Put_Int (" & To_String (M)
                                     & ");");
                     elsif Member = "LongReal" then
                        Append_Body ("      O2c_Put_LReal (" & To_String (M)
                                     & ");");
                     else
                        Append_Body ("      O2c_Put_Real (" & To_String (M)
                                     & ");");
                     end if;
                  else
                     raise O2c_Error with "Out supports String/Int/Real/"
                       & "LongReal/Char/Ln only (found Out." & Member
                       & ")";
                  end if;
               end;
            elsif Cur.Kind = Lex.Tok_LParen then
               if O2c_BC.Bytecode_Mode
                 and then Idx > 0
                 and then Syms (Idx).Kind /= S_Proc
                 and then Syms (Idx).UT > 0
                 and then UTypes (Syms (Idx).UT).Is_Proc
               then
                  --  Calling a procedure value: the callee is whatever the
                  --  variable holds, so load it and call through it.  Such a
                  --  procedure takes no arguments by definition, so there is
                  --  no argument list to parse - which is why this is a
                  --  separate branch and not a variant of the code below.
                  declare
                     --  Capture the name before advancing: Head is a lexer
                     --  buffer that Next overwrites, so reading it after the
                     --  tokens have moved on gives the wrong identifier.
                     Var : constant String := Ada_Id (Head (1 .. H_Len));
                  begin
                     Next;
                     Expect (Lex.Tok_RParen, "')' after a procedure value");
                     Next;
                     Bc_Load (Var);
                     O2c_BC.Call_Indirect;
                  end;
               else
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
                     if O2c_BC.Bytecode_Mode then
                        --  A call to something the emitter never opened is an
                        --  imported or undeclared procedure: fail loudly rather
                        --  than emit a call to procedure 0.
                        if Syms (Idx).Bc_Proc = 0 then
                           raise O2c_Error with "bytecode backend: call to '"
                             & Head (1 .. H_Len)
                             & "' resolved to symbol "
                             & Natural'Image (Idx) & " named '"
                             & To_String (Syms (Idx).Name)
                             & "' (kind " & Sym_Kind'Image (Syms (Idx).Kind)
                             & ", params" & Natural'Image (Syms (Idx).Params)
                             & ") with no procedure id";
                        end if;
                        if Syms (Idx).Foreign_Native /= 0 then
                           --  A foreign procedure: CALL_NATIVE rather than a
                           --  call to a body it does not have.
                           O2c_BC.Native_Call (Syms (Idx).Foreign_Native,
                                               Syms (Idx).Params);
                        else
                           O2c_BC.Call_Proc (Syms (Idx).Bc_Proc);
                        end if;
                     end if;
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
               end if;
            elsif Cur.Kind = Lex.Tok_Assign then
               if Idx = 0 or else Syms (Idx).Kind /= S_Var then
                  raise O2c_Error with "'" & Head (1 .. H_Len)
                    & "' is not a variable (line " & Natural'Image (Cur.Line)
                    & ")";
               end if;
               Next;
               if Syms (Idx).Typ = T_Char
                 and then Cur.Kind = Lex.Tok_String and then Cur.Len = 1
                 and then not O2c_BC.Bytecode_Mode
               then
                  Append_Body ("      " & Head (1 .. H_Len) & " := '"
                               & Cur.Text (1 .. 1) & "';");
                  Next;
               else
                  declare
                     V : Expr_Rec := Parse_Expr;
                  begin
                     if O2c_BC.Bytecode_Mode then
                        --  LONGINT is a 64-bit slot, the same as INTEGER:
                        --  no conversion is needed to assign one.  It was
                        --  missing from this list when the list was written.
                        if Syms (Idx).Typ /= T_Int
                          and then Syms (Idx).Typ /= T_Char
                          and then Syms (Idx).Typ /= T_Bool
                          and then Syms (Idx).Typ /= T_Set
                          and then Syms (Idx).Typ /= T_Real
                          and then Syms (Idx).Typ /= T_LReal
                          and then Syms (Idx).Typ /= T_Long
                        then
                           raise O2c_BC.Wrong_Construct with "bytecode "
                             & "backend: only INTEGER/CHAR/BOOLEAN "
                             & "assignments are supported";
                        end if;
                        Bc_Store (Ada_Id (Head (1 .. H_Len)));
                     end if;
                     if Syms (Idx).Typ = T_LReal then
                        if V.Typ = T_Int
                          or else (V.Typ = T_Real and then V.Lit)
                        then
                           Append_Body ("      " & Head (1 .. H_Len)
                                        & " := Long_Float ("
                                        & To_String (V.Text) & ");");
                        elsif V.Typ = T_LReal then
                           Append_Body ("      " & Head (1 .. H_Len)
                                        & " := " & To_String (V.Text) & ";");
                        else
                           raise O2c_Error with "type mismatch assigning "
                             & Head (1 .. H_Len);
                        end if;
                     elsif Syms (Idx).Typ = T_Real then
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
               --  A parameterless procedure is called without parentheses,
               --  so this is the only place such a call is seen.  Emitting
               --  just the Ada body made it a silent no-op in bytecode mode:
               --  parsed, accepted, and never called - which is the worst
               --  way for the most common statement in the language to fail.
               if O2c_BC.Bytecode_Mode then
                  if Syms (Idx).Bc_Proc = 0 then
                     raise O2c_BC.Wrong_Construct with
                       "bytecode backend: call to an unknown procedure";
                  end if;
                  O2c_BC.Call_Proc (Syms (Idx).Bc_Proc);
               end if;
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

   procedure Sh_Add (Owner, BOwn, BRec, MName : String) is
   begin
      N_Sh := N_Sh + 1;
      if N_Sh > Shs'Last then
         raise O2c_Error with "too many dispatch shadows";
      end if;
      Shs (N_Sh) := (Owner => To_Unbounded_String (Owner),
                     BOwn  => To_Unbounded_String (BOwn),
                     BRec  => To_Unbounded_String (BRec),
                     MName => To_Unbounded_String (MName));
   end Sh_Add;

   --  M31: the OUTERMOST (last-registered) shadow for a base/method:
   --  shadows chain, each falling back to the one registered before
   --  it, so the last one covers every override library.
   function Sh_Find (BOwn, BRec, MName : String) return Natural is
      Last : Natural := 0;
   begin
      for I in 1 .. N_Sh loop
         if To_String (Shs (I).BOwn) = BOwn
           and then To_String (Shs (I).BRec) = BRec
           and then To_String (Shs (I).MName) = MName
         then
            Last := I;
         end if;
      end loop;
      return Last;
   end Sh_Find;

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
                          (Qual_UT (Syms (SIdx).P (I).UT));
                        E.P (I - 1).Typ := T_Int;
                     end if;
                  end loop;
                  if Syms (SIdx).Ret and then Syms (SIdx).UT /= 0 then
                     E.Ret_Nm := To_Unbounded_String (Qual_UT (Syms (SIdx).UT));
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
                                        & Ada_Last (To_String (UTypes (Cand (I)).Name))
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

      --  M29: widened-pointer dispatch shadows.  When an exported
      --  procedure method on an exported local RECORD overrides a
      --  method of its imported exported parent, also export a shadow
      --  dispatcher on the parent view: it dispatches this module's
      --  subtree and falls back to the parent module's dispatcher, so
      --  base-typed pointers held by importers reach this override.
      for Bd in 1 .. N_Bound loop
         declare
            SIdx : constant Natural := Bounds (Bd).SymIdx;
            R    : constant Natural := Bounds (Bd).RecUT;
            DN   : constant String := To_String (Bounds (Bd).Name);
         begin
            if Syms (SIdx).Exp and then UTypes (R).ExpT
              and then UTypes (R).Parent /= 0
              and then UTypes (UTypes (R).Parent).Imported
              and then XM_Chain (UTypes (R).Parent, DN) /= 0
            then
               declare
                  PB    : constant Natural := UTypes (R).Parent;
                  PNm   : constant String := To_String (UTypes (PB).Name);
                  PSh   : constant String := Short_Nm (PNm);
                  BOwn  : constant String := UT_Owner (PB);
                  RcvrN : constant String :=
                    To_String (Syms (SIdx).P (1).Name);
                  Hdr   : Unbounded_String;
                  ArgL  : Unbounded_String;
                  Cand  : array (1 .. Max_Bound) of Natural :=
                    (others => 0);
                  N_C   : Natural := 0;
                  PrevSh : constant Natural := Sh_Find (BOwn, PSh, DN);
                  FB    : Unbounded_String;
                  Rpre  : constant String :=
                    (if Syms (SIdx).Ret then "return " else "");
                  Knd   : constant String :=
                    (if Syms (SIdx).Ret then "function " else "procedure ");
                  RetT  : constant String :=
                    (if Syms (SIdx).Ret then
                        (if Syms (SIdx).UT /= 0
                           then Qual_UT (Syms (SIdx).UT)
                           else Ada_Type (Syms (SIdx).Typ))
                     else "");
               begin
                  Hdr := Hdr & Knd & DN & "_Any_Disp_O2c_"
                    & PSh & " (" & RcvrN
                    & (if Syms (SIdx).P (1).By_Ref
                       then " : in out " else " : ")
                    & Ada_Last (PNm) & "'Class";
                  for I in 2 .. Syms (SIdx).Params loop
                     Hdr := Hdr & "; " & To_String (Syms (SIdx).P (I).Name)
                       & (if Syms (SIdx).P (I).By_Ref
                          then " : in out " else " : ")
                       & P_Ada_Type (Syms (SIdx).P (I));
                     if I > 2 then
                        ArgL := ArgL & ", ";
                     end if;
                     ArgL := ArgL & To_String (Syms (SIdx).P (I).Name);
                  end loop;
                  Hdr := Hdr & ")";
                  if Syms (SIdx).Ret then
                     Hdr := Hdr & " return " & RetT;
                  end if;
                  for X in 1 .. N_UT loop
                     if UTypes (X).Is_Rec and then X /= R
                       and then Rec_Descends (X, R)
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
                  FB := To_Unbounded_String
                    (BOwn & "." & DN & "_Disp_O2c_" & PSh);
                  if PrevSh /= 0 then
                     --  chain to the previously-registered shadow so
                     --  multiple override libraries compose (M31)
                     Add_BW (To_String (Shs (PrevSh).Owner));
                     FB := To_Unbounded_String
                       (Ada_Id (To_String (Shs (PrevSh).Owner)) & "."
                        & DN
                        & "_Any_Disp_O2c_" & PSh);
                  end if;
                  Append_Spec ("   " & To_String (Hdr) & ";");
                  Append_Decl ("   " & To_String (Hdr) & " is");
                  Append_Decl ("   begin");
                  if N_C > 0 then
                     for I in 1 .. N_C loop
                        Append_Decl ("      "
                                     & (if I = 1 then "if " else "elsif ")
                                     & RcvrN & " in "
                                     & Ada_Last (To_String (UTypes (Cand (I)).Name))
                                     & "'Class then");
                        Append_Decl ("         " & Rpre
                                     & Method_Impl_Name (DN, Cand (I))
                                     & " (" & To_String
                                         (UTypes (Cand (I)).Name) & " ("
                                     & RcvrN & ")"
                                     & (if Syms (SIdx).Params > 1
                                        then ", " & To_String (ArgL)
                                        else "") & ");");
                     end loop;
                     Append_Decl ("      else");
                  end if;
                  --  this module's override subtree first, then the
                  --  base module's dispatcher for everything else
                  Append_Decl ("         if " & RcvrN & " in "
                               & Ada_Last (To_String (UTypes (R).Name))
                               & "'Class then");
                  Append_Decl ("            " & Rpre
                               & Method_Impl_Name (DN, R) & " ("
                               & Ada_Last (To_String (UTypes (R).Name)) & " (" & RcvrN
                               & ")"
                               & (if Syms (SIdx).Params > 1
                                  then ", " & To_String (ArgL)
                                  else "") & ");");
                  Append_Decl ("         else");
                  Append_Decl ("            " & Rpre & To_String (FB)
                               & " (" & RcvrN
                               & (if Syms (SIdx).Params > 1
                                  then ", " & To_String (ArgL)
                                  else "") & ");");
                  Append_Decl ("         end if;");
                  if N_C > 0 then
                     Append_Decl ("      end if;");
                  end if;
                  Append_Decl ("   end " & DN & "_Any_Disp_O2c_" & PSh
                               & ";");
                  Sh_Add (To_String (Mod_Name), BOwn, PSh, DN);
               end;
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
         --  M21: in a multi-module build the support types live in the
         --  shared O2c_Types package (with/use emitted per unit), so no
         --  unit declares them locally.
         if Used_Int_Arr and then not Multi_Ok
           and then not (Pkg_Mode and then Base_In_Spec)
         then
            S := S & "   type O2c_Int_Arr is array (Integer range <>) of Integer;"
              & ASCII.LF;
         end if;
         if Used_Bool_Arr and then not Multi_Ok
           and then not (Pkg_Mode and then Base_In_Spec)
         then
            S := S & "   type O2c_Bool_Arr is array (Integer range <>) of Boolean;"
              & ASCII.LF;
         end if;
         if Used_Set and then not Multi_Ok then
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
              & "      if FR > 999 then IP := IP + 1; FR := 0; end if;"
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
         if Used_LReal then
            S := S & "   procedure O2c_Put_LReal (V : Long_Float) is"
              & ASCII.LF
              & "      IP : Long_Integer;" & ASCII.LF
              & "      FR : Long_Integer;" & ASCII.LF
              & "   begin" & ASCII.LF
              & "      IP := Long_Integer (V - 0.5);" & ASCII.LF
              & "      if V < 0.0 then IP := IP + 1; end if;" & ASCII.LF
              & "      FR := Long_Integer (abs (V - Long_Float (IP))"
              & " * 1000000.0);" & ASCII.LF
              & "      if FR > 999999 then IP := IP + 1; FR := 0; end if;"
              & ASCII.LF
              & "      declare" & ASCII.LF
              & "         Img : constant String := Long_Integer'Image (IP);"
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
              & "         D6 : constant String :=" & ASCII.LF
              & "           Character'Val (48 + Integer (FR / 100000))"
              & ASCII.LF
              & "           & Character'Val (48 + Integer ((FR / 10000)"
              & " mod 10))" & ASCII.LF
              & "           & Character'Val (48 + Integer ((FR / 1000)"
              & " mod 10))" & ASCII.LF
              & "           & Character'Val (48 + Integer ((FR / 100)"
              & " mod 10))" & ASCII.LF
              & "           & Character'Val (48 + Integer ((FR / 10)"
              & " mod 10))" & ASCII.LF
              & "           & Character'Val (48 + Integer (FR mod 10));"
              & ASCII.LF
              & "      begin" & ASCII.LF
              & "         Aegir_User.Console.Put (D6);" & ASCII.LF
              & "      end;" & ASCII.LF
              & "   end O2c_Put_LReal;" & ASCII.LF;
         end if;
         if Used_StrCmp then
            --  M33: string comparison over NUL-terminated content
            S := S & "   function O2c_S_Cmp (A, B : String) "
              & "return Integer is" & ASCII.LF
              & "      Na : Natural := 0; Nb : Natural := 0; K : Natural;"
              & ASCII.LF
              & "   begin" & ASCII.LF
              & "      K := A'First;" & ASCII.LF
              & "      while K <= A'Last and then A (K) /= ASCII.NUL loop"
              & ASCII.LF
              & "         Na := K; K := K + 1;" & ASCII.LF
              & "      end loop;" & ASCII.LF
              & "      K := B'First;" & ASCII.LF
              & "      while K <= B'Last and then B (K) /= ASCII.NUL loop"
              & ASCII.LF
              & "         Nb := K; K := K + 1;" & ASCII.LF
              & "      end loop;" & ASCII.LF
              & "      K := 1;" & ASCII.LF
              & "      while K <= Na - A'First + 1 and then "
              & "K <= Nb - B'First + 1 loop" & ASCII.LF
              & "         if A (A'First + K - 1) /= B (B'First + K - 1)"
              & " then" & ASCII.LF
              & "            if A (A'First + K - 1) < B (B'First + K - 1)"
              & " then" & ASCII.LF
              & "               return -1;" & ASCII.LF
              & "            else" & ASCII.LF
              & "               return 1;" & ASCII.LF
              & "            end if;" & ASCII.LF
              & "         end if;" & ASCII.LF
              & "         K := K + 1;" & ASCII.LF
              & "      end loop;" & ASCII.LF
              & "      if (Na - A'First + 1) /= (Nb - B'First + 1) then"
              & ASCII.LF
              & "         return (if (Na - A'First + 1) < "
              & "(Nb - B'First + 1) then -1 else 1);" & ASCII.LF
              & "      end if;" & ASCII.LF
              & "      return 0;" & ASCII.LF
              & "   end O2c_S_Cmp;" & ASCII.LF;
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
      Used_LReal := False;
      Used_StrCmp := False;
      Used_Console := False;
      Base_In_Spec := False;
      RVar_N := 0;
      N_SW := 0;
      N_BW := 0;
      N_Bound := 0;
      Recv_UT := 0;
      G_N := 0;
      N_Dsp := 0;
      N_Imp := 0;
      Nested_Depth := 0;
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
         --  The module body is the last procedure in the image, so it is
         --  opened here: after every declared procedure has been emitted and
         --  closed, which is exactly what the CODE procedure table assumes
         --  (and what the header's entry points at).
         if O2c_BC.Bytecode_Mode then
            O2c_BC.Begin_Body;
         end if;
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
         for I in 1 .. RVar_N loop
            Append_Spec (To_String (RVar_Specs (I)));
         end loop;
         RVar_N := 0;
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
            if Multi_Ok then
               S := S & "with O2c_Types; use O2c_Types;" & ASCII.LF;
            end if;
            for I in 1 .. N_Imp loop
               if To_String (Imports (I).Name) /= "Out" then
                  S := S & "with "
                    & Ada_Id (To_String (Imports (I).Name)) & ";"
                    & ASCII.LF;
               end if;
            end loop;
            S := S & ASCII.LF;
            S := S & "procedure " & Ada_Id (To_String (Mod_Name))
              & " is" & ASCII.LF;
            Emit_Helpers (S);
            S := S & To_String (Decl_Buf);
            S := S & "begin" & ASCII.LF;
            S := S & "   Aegir_User.Console.Set_Endpoint (1);" & ASCII.LF;
            S := S & To_String (Body_Buf);
            S := S & "end " & Ada_Id (To_String (Mod_Name)) & ";"
              & ASCII.LF;
            Main_Txt := S;
         end;
      else
         --  library module: an Ada package spec plus body.  The body
         --  carries the module state, private declarations, procedure
         --  bodies and the module initialisation statements (Ada
         --  elaboration runs them before the importer's body).
         Spec_Txt := To_Unbounded_String
           (if Multi_Ok
            then "with O2c_Types; use O2c_Types;" & ASCII.LF
            else "")
           & (if Multi_Ok then Spec_With_Lines else "")
           & (if not Multi_Ok and then Base_In_Spec and then Used_Int_Arr
              then "   type O2c_Int_Arr is array (Integer range <>)"
                & " of Integer;" & ASCII.LF
              else "")
           & (if not Multi_Ok and then Base_In_Spec and then Used_Bool_Arr
              then "   type O2c_Bool_Arr is array (Integer range <>)"
                & " of Boolean;" & ASCII.LF
              else "")
           & To_Unbounded_String
             ("package " & Ada_Id (To_String (Mod_Name)) & " is"
              & ASCII.LF)
           & Spec_Buf
           & To_Unbounded_String
             ("end " & Ada_Id (To_String (Mod_Name)) & ";"
              & ASCII.LF);
         declare
            S : Unbounded_String;
         begin
            if Used_Console then
               S := S & "with Aegir_User.Console;" & ASCII.LF;
            end if;
            if Used_Set then
               S := S & "with Interfaces;" & ASCII.LF;
            end if;
            if Multi_Ok then
               S := S & "with O2c_Types; use O2c_Types;" & ASCII.LF;
            end if;
            for I in 1 .. N_Imp loop
               if To_String (Imports (I).Name) /= "Out" then
                  S := S & "with "
                    & Ada_Id (To_String (Imports (I).Name)) & ";"
                    & ASCII.LF;
               end if;
            end loop;
            for I in 1 .. N_BW loop
               S := S & "with " & Ada_Id (To_String (Body_Withs (I)))
                 & ";" & ASCII.LF;
            end loop;
            if To_String (Mod_Name) = "Files" then
               S := S & "with Aegir_User.Files;" & ASCII.LF
                 & "with Aegir_User.CLI;" & ASCII.LF
                 & "with Interfaces;" & ASCII.LF;
            end if;
            if To_String (Mod_Name) = "Math" then
               S := S & "with Ada.Numerics.Elementary_Functions;" & ASCII.LF;
            end if;
            if To_String (Mod_Name) = "MathL" then
               S := S & "with Ada.Numerics.Long_Elementary_Functions;"
                 & ASCII.LF;
            end if;
            if To_String (Mod_Name) = "In" then
               S := S & "with Aegir_User.CLI;" & ASCII.LF;
            end if;
            if To_String (Mod_Name) = "Input" then
               S := S & "with Aegir_User.CLI;" & ASCII.LF
                 & "with Aegir_User.Syscalls;" & ASCII.LF;
            end if;
            if To_String (Mod_Name) = "XYplane" then
               S := S & "with Aegir_User.CLI;" & ASCII.LF
                 & "with Interfaces;" & ASCII.LF;
            end if;
            if To_String (Mod_Name) = "Args" then
               S := S & "with Aegir_User.CLI;" & ASCII.LF;
            end if;
            if To_String (Mod_Name) = "Env" then
               S := S & "with Aegir_User.CLI;" & ASCII.LF;
            end if;
            if Length (S) > 0 then
               S := S & ASCII.LF;
            end if;
            S := S & "package body " & Ada_Id (To_String (Mod_Name))
              & " is" & ASCII.LF;
            Emit_Helpers (S);
            if To_String (Mod_Name) = "Files" then
               --  M40 FFI: private named-read helpers on the file server
               S := S
                 & "   --  Oberon ARRAY OF CHAR names are space-filled (Oakwood"
                 & ASCII.LF
                 & "   --  convention) and may carry a terminating NUL; the file"
                 & ASCII.LF
                 & "   --  server wants the bare name, so trim at the first NUL"
                 & ASCII.LF
                 & "   --  and then drop trailing spaces." & ASCII.LF
                 & "   function O2c_Name (S : String) return String is" & ASCII.LF
                 & "   begin" & ASCII.LF
                 & "      for I in S'Range loop" & ASCII.LF
                 & "         if S (I) = ASCII.NUL then" & ASCII.LF
                 & "            return S (S'First .. I - 1);" & ASCII.LF
                 & "         end if;" & ASCII.LF
                 & "      end loop;" & ASCII.LF
                 & "      for I in reverse S'Range loop" & ASCII.LF
                 & "         if S (I) /= ' ' then" & ASCII.LF
                 & "            return S (S'First .. I);" & ASCII.LF
                 & "         end if;" & ASCII.LF
                 & "      end loop;" & ASCII.LF
                 & "      return """";" & ASCII.LF
                 & "   end O2c_Name;" & ASCII.LF
                 & "   function O2c_FStat (Nm : String) return Long_Integer is"
                 & ASCII.LF
                 & "      use type Interfaces.Unsigned_64;" & ASCII.LF
                 & "      Sz : Interfaces.Unsigned_64;" & ASCII.LF
                 & "   begin" & ASCII.LF
                 & "      Aegir_User.CLI.Init;" & ASCII.LF
                 & "      if Aegir_User.Files.Stat (O2c_Name (Nm), Sz) /= "
                 & "Aegir_User.Files.Status_Ok then" & ASCII.LF
                 & "         return -1;" & ASCII.LF
                 & "      end if;" & ASCII.LF
                 & "      return Long_Integer (Sz);" & ASCII.LF
                 & "   end O2c_FStat;" & ASCII.LF
                 & "   function O2c_FRead (Nm : String;"
                 & " Off : Long_Integer;"
                 & " Buf : in out String) return Integer is" & ASCII.LF
                 & "      use type Interfaces.Unsigned_64;" & ASCII.LF
                 & "      Sz, Cn, Lim : Interfaces.Unsigned_64;" & ASCII.LF
                 & "      St : Interfaces.Unsigned_64;" & ASCII.LF
                 & "   begin" & ASCII.LF
                 & "      Aegir_User.CLI.Init;" & ASCII.LF
                 & "      if Off < 0 then" & ASCII.LF
                 & "         return 1;" & ASCII.LF
                 & "      end if;" & ASCII.LF
                 & "      St := Aegir_User.Files.Open (O2c_Name (Nm), Sz);" & ASCII.LF
                 & "      if St /= Aegir_User.Files.Status_Ok then"
                 & ASCII.LF
                 & "         return Integer (St);" & ASCII.LF
                 & "      end if;" & ASCII.LF
                 & "      if Interfaces.Unsigned_64 (Off) >= Sz then"
                 & ASCII.LF
                 & "         return 0;" & ASCII.LF
                 & "      end if;" & ASCII.LF
                 & "      Lim := Interfaces.Unsigned_64 (Buf'Length);"
                 & ASCII.LF
                 & "      if Lim > 32768 then" & ASCII.LF
                 & "         Lim := 32768;" & ASCII.LF
                 & "      end if;" & ASCII.LF
                 & "      if Lim > Sz - Interfaces.Unsigned_64 (Off) then"
                 & ASCII.LF
                 & "         Lim := Sz - Interfaces.Unsigned_64 (Off);"
                 & ASCII.LF
                 & "      end if;" & ASCII.LF
                 & "      St := Aegir_User.Files.Read"
                 & " (O2c_Name (Nm), Interfaces.Unsigned_64 (Off)," & ASCII.LF
                 & "               Buf'Address, Lim, Cn);" & ASCII.LF
                 & "      if St /= Aegir_User.Files.Status_Ok then"
                 & ASCII.LF
                 & "         return Integer (St);" & ASCII.LF
                 & "      end if;" & ASCII.LF
                 & "      if Cn = 0 then" & ASCII.LF
                 & "         return 0;" & ASCII.LF
                 & "      end if;" & ASCII.LF
                 & "      return 0;" & ASCII.LF
                 & "   end O2c_FRead;" & ASCII.LF
                 & "   function O2c_FWrite (Nm : String;"
                 & " Off : Long_Integer;"
                 & " Buf : String) return Integer is" & ASCII.LF
                 & "      use type Interfaces.Unsigned_64;" & ASCII.LF
                 & "      Cn, St : Interfaces.Unsigned_64;" & ASCII.LF
                 & "   begin" & ASCII.LF
                 & "      Aegir_User.CLI.Init;" & ASCII.LF
                 & "      if Off < 0 then" & ASCII.LF
                 & "         return 1;" & ASCII.LF
                 & "      end if;" & ASCII.LF
                 & "      St := Aegir_User.Files.Write"
                 & " (O2c_Name (Nm), Interfaces.Unsigned_64 (Off)," & ASCII.LF
                 & "               Buf'Address,"
                 & " Interfaces.Unsigned_64 (Buf'Length), Cn);" & ASCII.LF
                 & "      if St /= Aegir_User.Files.Status_Ok then"
                 & ASCII.LF
                 & "         return Integer (St);" & ASCII.LF
                 & "      end if;" & ASCII.LF
                 & "      if Cn = 0 then" & ASCII.LF
                 & "         return 1;" & ASCII.LF
                 & "      end if;" & ASCII.LF
                 & "      return 0;" & ASCII.LF
                 & "   end O2c_FWrite;" & ASCII.LF
                 & "   function O2c_FClose (Nm : String) return Integer is"
                 & ASCII.LF
                 & "      use type Interfaces.Unsigned_64;" & ASCII.LF
                 & "      St : Interfaces.Unsigned_64;" & ASCII.LF
                 & "   begin" & ASCII.LF
                 & "      Aegir_User.CLI.Init;" & ASCII.LF
                 & "      St := Aegir_User.Files.Close (O2c_Name (Nm));" & ASCII.LF
                 & "      if St /= Aegir_User.Files.Status_Ok then"
                 & ASCII.LF
                 & "         return Integer (St);" & ASCII.LF
                 & "      end if;" & ASCII.LF
                 & "      return 0;" & ASCII.LF
                 & "   end O2c_FClose;" & ASCII.LF
                 & "   procedure O2c_FRename (From, To : String) is"
                 & ASCII.LF
                 & "      use type Interfaces.Unsigned_64;" & ASCII.LF
                 & "      St : Interfaces.Unsigned_64;" & ASCII.LF
                 & "   begin" & ASCII.LF
                 & "      Aegir_User.CLI.Init;" & ASCII.LF
                 & "      St := Aegir_User.Files.Rename (O2c_Name (From), O2c_Name (To));" & ASCII.LF
                 & "      if St = 0 then" & ASCII.LF
                 & "         return;" & ASCII.LF
                 & "      end if;" & ASCII.LF
                 & "   end O2c_FRename;" & ASCII.LF
                 & "   procedure O2c_FDel (Nm : String) is" & ASCII.LF
                 & "      use type Interfaces.Unsigned_64;" & ASCII.LF
                 & "      St : Interfaces.Unsigned_64;" & ASCII.LF
                 & "   begin" & ASCII.LF
                 & "      Aegir_User.CLI.Init;" & ASCII.LF
                 & "      St := Aegir_User.Files.Delete (O2c_Name (Nm));" & ASCII.LF
                 & "      if St = 0 then" & ASCII.LF
                 & "         return;" & ASCII.LF
                 & "      end if;" & ASCII.LF
                 & "   end O2c_FDel;" & ASCII.LF;
            end if;
            if To_String (Mod_Name) = "In" then
               --  M45 FFI: console input (builtin In module): the whole
               --  stdin is pulled once through CLI.Get_Line (args-page
               --  in_path; no in_path => EOF) and scanned as
               --  whitespace-separated tokens.
               S := S
                 & "   In_Buf : String (1 .. 4096);" & ASCII.LF
                 & "   In_Len : Natural := 0;" & ASCII.LF
                 & "   In_Pos : Natural := 1;" & ASCII.LF
                 & "   In_Rdy : Boolean := False;" & ASCII.LF
                 & "" & ASCII.LF
                 & "   procedure O2c_In_Load is" & ASCII.LF
                 & "      S : String (1 .. 512);" & ASCII.LF
                 & "      L : Natural;" & ASCII.LF
                 & "      E : Boolean;" & ASCII.LF
                 & "   begin" & ASCII.LF
                 & "      Aegir_User.CLI.Init;" & ASCII.LF
                 & "      if In_Rdy then" & ASCII.LF
                 & "         return;" & ASCII.LF
                 & "      end if;" & ASCII.LF
                 & "      In_Rdy := True;" & ASCII.LF
                 & "      loop" & ASCII.LF
                 & "         Aegir_User.CLI.Get_Line (S, L, E);" & ASCII.LF
                 & "         exit when E;" & ASCII.LF
                 & "         exit when In_Len + L + 1 > 4096;" & ASCII.LF
                 & "         for I in 1 .. L loop" & ASCII.LF
                 & "            In_Len := In_Len + 1;" & ASCII.LF
                 & "            In_Buf (In_Len) := S (I);" & ASCII.LF
                 & "         end loop;" & ASCII.LF
                 & "         In_Len := In_Len + 1;" & ASCII.LF
                 & "         In_Buf (In_Len) := ' ';" & ASCII.LF
                 & "      end loop;" & ASCII.LF
                 & "   end O2c_In_Load;" & ASCII.LF
                 & "" & ASCII.LF
                 & "   procedure O2c_In_Reset is" & ASCII.LF
                 & "   begin" & ASCII.LF
                 & "      In_Rdy := False;" & ASCII.LF
                 & "      In_Len := 0;" & ASCII.LF
                 & "      In_Pos := 1;" & ASCII.LF
                 & "   end O2c_In_Reset;" & ASCII.LF
                 & "" & ASCII.LF
                 & "   procedure O2c_In_Skip is" & ASCII.LF
                 & "   begin" & ASCII.LF
                 & "      O2c_In_Load;" & ASCII.LF
                 & "      while In_Pos <= In_Len and then In_Buf (In_Pos) = ' ' loop" & ASCII.LF
                 & "         In_Pos := In_Pos + 1;" & ASCII.LF
                 & "      end loop;" & ASCII.LF
                 & "   end O2c_In_Skip;" & ASCII.LF
                 & "" & ASCII.LF
                 & "   procedure O2c_In_Token (First : out Natural; Last : out Natural) is" & ASCII.LF
                 & "   begin" & ASCII.LF
                 & "      O2c_In_Skip;" & ASCII.LF
                 & "      First := In_Pos;" & ASCII.LF
                 & "      while In_Pos <= In_Len and then In_Buf (In_Pos) /= ' ' loop" & ASCII.LF
                 & "         In_Pos := In_Pos + 1;" & ASCII.LF
                 & "      end loop;" & ASCII.LF
                 & "      Last := In_Pos - 1;" & ASCII.LF
                 & "   end O2c_In_Token;" & ASCII.LF
                 & "" & ASCII.LF
                 & "   function O2c_In_Char return Character is" & ASCII.LF
                 & "      C : Character;" & ASCII.LF
                 & "   begin" & ASCII.LF
                 & "      O2c_In_Skip;" & ASCII.LF
                 & "      if In_Pos > In_Len then" & ASCII.LF
                 & "         Done := False;" & ASCII.LF
                 & "         return ' ';" & ASCII.LF
                 & "      end if;" & ASCII.LF
                 & "      Done := True;" & ASCII.LF
                 & "      C := In_Buf (In_Pos);" & ASCII.LF
                 & "      In_Pos := In_Pos + 1;" & ASCII.LF
                 & "      return C;" & ASCII.LF
                 & "   end O2c_In_Char;" & ASCII.LF
                 & "" & ASCII.LF
                 & "   function O2c_In_Int return Integer is" & ASCII.LF
                 & "      F, L : Natural;" & ASCII.LF
                 & "      V : Integer := 0;" & ASCII.LF
                 & "      K : Natural;" & ASCII.LF
                 & "      Neg : Boolean := False;" & ASCII.LF
                 & "   begin" & ASCII.LF
                 & "      O2c_In_Token (F, L);" & ASCII.LF
                 & "      if F > L then" & ASCII.LF
                 & "         Done := False;" & ASCII.LF
                 & "         return 0;" & ASCII.LF
                 & "      end if;" & ASCII.LF
                 & "      K := F;" & ASCII.LF
                 & "      if In_Buf (K) = '-' then" & ASCII.LF
                 & "         Neg := True;" & ASCII.LF
                 & "         K := K + 1;" & ASCII.LF
                 & "      elsif In_Buf (K) = '+' then" & ASCII.LF
                 & "         K := K + 1;" & ASCII.LF
                 & "      end if;" & ASCII.LF
                 & "      if K > L then" & ASCII.LF
                 & "         Done := False;" & ASCII.LF
                 & "         return 0;" & ASCII.LF
                 & "      end if;" & ASCII.LF
                 & "      for I in K .. L loop" & ASCII.LF
                 & "         exit when In_Buf (I) not in '0' .. '9';" & ASCII.LF
                 & "         V := V * 10 + (Character'Pos (In_Buf (I))" & ASCII.LF
                 & "                        - Character'Pos ('0'));" & ASCII.LF
                 & "      end loop;" & ASCII.LF
                 & "      if In_Buf (L) not in '0' .. '9' then" & ASCII.LF
                 & "         Done := False;" & ASCII.LF
                 & "         return 0;" & ASCII.LF
                 & "      end if;" & ASCII.LF
                 & "      Done := True;" & ASCII.LF
                 & "      if Neg then" & ASCII.LF
                 & "         return -V;" & ASCII.LF
                 & "      end if;" & ASCII.LF
                 & "      return V;" & ASCII.LF
                 & "   end O2c_In_Int;" & ASCII.LF
                 & "" & ASCII.LF
                 & "   function O2c_In_Long return Long_Integer is" & ASCII.LF
                 & "      F, L : Natural;" & ASCII.LF
                 & "      V : Long_Integer := 0;" & ASCII.LF
                 & "      K : Natural;" & ASCII.LF
                 & "      Neg : Boolean := False;" & ASCII.LF
                 & "   begin" & ASCII.LF
                 & "      O2c_In_Token (F, L);" & ASCII.LF
                 & "      if F > L then" & ASCII.LF
                 & "         Done := False;" & ASCII.LF
                 & "         return 0;" & ASCII.LF
                 & "      end if;" & ASCII.LF
                 & "      K := F;" & ASCII.LF
                 & "      if In_Buf (K) = '-' then" & ASCII.LF
                 & "         Neg := True;" & ASCII.LF
                 & "         K := K + 1;" & ASCII.LF
                 & "      elsif In_Buf (K) = '+' then" & ASCII.LF
                 & "         K := K + 1;" & ASCII.LF
                 & "      end if;" & ASCII.LF
                 & "      if K > L then" & ASCII.LF
                 & "         Done := False;" & ASCII.LF
                 & "         return 0;" & ASCII.LF
                 & "      end if;" & ASCII.LF
                 & "      for I in K .. L loop" & ASCII.LF
                 & "         exit when In_Buf (I) not in '0' .. '9';" & ASCII.LF
                 & "         V := V * 10 + Long_Integer (Character'Pos (In_Buf (I))" & ASCII.LF
                 & "                                     - Character'Pos ('0'));" & ASCII.LF
                 & "      end loop;" & ASCII.LF
                 & "      if In_Buf (L) not in '0' .. '9' then" & ASCII.LF
                 & "         Done := False;" & ASCII.LF
                 & "         return 0;" & ASCII.LF
                 & "      end if;" & ASCII.LF
                 & "      Done := True;" & ASCII.LF
                 & "      if Neg then" & ASCII.LF
                 & "         return -V;" & ASCII.LF
                 & "      end if;" & ASCII.LF
                 & "      return V;" & ASCII.LF
                 & "   end O2c_In_Long;" & ASCII.LF
                 & "" & ASCII.LF
                 & "   function O2c_In_Real return Float is" & ASCII.LF
                 & "      F, L : Natural;" & ASCII.LF
                 & "      V : Float := 0.0;" & ASCII.LF
                 & "      K : Natural;" & ASCII.LF
                 & "      Neg : Boolean := False;" & ASCII.LF
                 & "      Frac : Float := 0.1;" & ASCII.LF
                 & "      Seen_Dot : Boolean := False;" & ASCII.LF
                 & "      Seen_Dig : Boolean := False;" & ASCII.LF
                 & "   begin" & ASCII.LF
                 & "      O2c_In_Token (F, L);" & ASCII.LF
                 & "      if F > L then" & ASCII.LF
                 & "         Done := False;" & ASCII.LF
                 & "         return 0.0;" & ASCII.LF
                 & "      end if;" & ASCII.LF
                 & "      K := F;" & ASCII.LF
                 & "      if In_Buf (K) = '-' then" & ASCII.LF
                 & "         Neg := True;" & ASCII.LF
                 & "         K := K + 1;" & ASCII.LF
                 & "      elsif In_Buf (K) = '+' then" & ASCII.LF
                 & "         K := K + 1;" & ASCII.LF
                 & "      end if;" & ASCII.LF
                 & "      if K > L then" & ASCII.LF
                 & "         Done := False;" & ASCII.LF
                 & "         return 0.0;" & ASCII.LF
                 & "      end if;" & ASCII.LF
                 & "      for I in K .. L loop" & ASCII.LF
                 & "         if In_Buf (I) in '0' .. '9' then" & ASCII.LF
                 & "            Seen_Dig := True;" & ASCII.LF
                 & "            if Seen_Dot then" & ASCII.LF
                 & "               V := V + Float (Character'Pos (In_Buf (I))" & ASCII.LF
                 & "                               - Character'Pos ('0')) * Frac;" & ASCII.LF
                 & "               Frac := Frac / 10.0;" & ASCII.LF
                 & "            else" & ASCII.LF
                 & "               V := V * 10.0 + Float (Character'Pos (In_Buf (I))" & ASCII.LF
                 & "                                      - Character'Pos ('0'));" & ASCII.LF
                 & "            end if;" & ASCII.LF
                 & "         elsif In_Buf (I) = '.' and then not Seen_Dot then" & ASCII.LF
                 & "            Seen_Dot := True;" & ASCII.LF
                 & "         else" & ASCII.LF
                 & "            Done := False;" & ASCII.LF
                 & "            return 0.0;" & ASCII.LF
                 & "         end if;" & ASCII.LF
                 & "      end loop;" & ASCII.LF
                 & "      if not Seen_Dig then" & ASCII.LF
                 & "         Done := False;" & ASCII.LF
                 & "         return 0.0;" & ASCII.LF
                 & "      end if;" & ASCII.LF
                 & "      Done := True;" & ASCII.LF
                 & "      if Neg then" & ASCII.LF
                 & "         return -V;" & ASCII.LF
                 & "      end if;" & ASCII.LF
                 & "      return V;" & ASCII.LF
                 & "   end O2c_In_Real;" & ASCII.LF
                 & "" & ASCII.LF
                 & "   procedure O2c_In_Word (Buf : out String) is" & ASCII.LF
                 & "      F, L : Natural;" & ASCII.LF
                 & "      N : Natural := 0;" & ASCII.LF
                 & "   begin" & ASCII.LF
                 & "      O2c_In_Token (F, L);" & ASCII.LF
                 & "      for I in F .. L loop" & ASCII.LF
                 & "         exit when N >= Buf'Length - 1;" & ASCII.LF
                 & "         N := N + 1;" & ASCII.LF
                 & "         Buf (Buf'First + N - 1) := In_Buf (I);" & ASCII.LF
                 & "      end loop;" & ASCII.LF
                 & "      for I in N + 1 .. Buf'Length loop" & ASCII.LF
                 & "         Buf (Buf'First + I - 1) := Character'Val (0);" & ASCII.LF
                 & "      end loop;" & ASCII.LF
                 & "      Done := N > 0;" & ASCII.LF
                 & "   end O2c_In_Word;" & ASCII.LF
                 & "" & ASCII.LF
                 & "   procedure O2c_In_Name (Buf : out String) is" & ASCII.LF
                 & "      F, L : Natural;" & ASCII.LF
                 & "      N : Natural := 0;" & ASCII.LF
                 & "   begin" & ASCII.LF
                 & "      O2c_In_Token (F, L);" & ASCII.LF
                 & "      for I in F .. L loop" & ASCII.LF
                 & "         exit when N >= Buf'Length - 1;" & ASCII.LF
                 & "         exit when not (In_Buf (I) in 'A' .. 'Z'" & ASCII.LF
                 & "                        or else In_Buf (I) in 'a' .. 'z'" & ASCII.LF
                 & "                        or else In_Buf (I) in '0' .. '9'" & ASCII.LF
                 & "                        or else In_Buf (I) = '_');" & ASCII.LF
                 & "         N := N + 1;" & ASCII.LF
                 & "         Buf (Buf'First + N - 1) := In_Buf (I);" & ASCII.LF
                 & "      end loop;" & ASCII.LF
                 & "      for I in N + 1 .. Buf'Length loop" & ASCII.LF
                 & "         Buf (Buf'First + I - 1) := Character'Val (0);" & ASCII.LF
                 & "      end loop;" & ASCII.LF
                 & "      Done := N > 0;" & ASCII.LF
                 & "   end O2c_In_Name;" & ASCII.LF
                 & "";
            end if;
            if To_String (Mod_Name) = "Input" then
               --  M48 FFI: keyboard/clock access for the Oakwood Input
               --  module.  The console ABI has no keyboard queue, so
               --  Read drains the same stdin in_path that In uses (a
               --  newline is kept between lines) and answers CHR(0)
               --  at end of input; Time comes from the wall clock.
               S := S
                 & "   In_C_Buf : String (1 .. 4096);" & ASCII.LF
                 & "   In_C_Len : Natural := 0;" & ASCII.LF
                 & "   In_C_Pos : Natural := 1;" & ASCII.LF
                 & "   In_C_Rdy : Boolean := False;" & ASCII.LF
                 & "   procedure O2c_In_Cload is" & ASCII.LF
                 & "      S : String (1 .. 512);" & ASCII.LF
                 & "      L : Natural;" & ASCII.LF
                 & "      E : Boolean;" & ASCII.LF
                 & "   begin" & ASCII.LF
                 & "      Aegir_User.CLI.Init;" & ASCII.LF
                 & "      if In_C_Rdy then" & ASCII.LF
                 & "         return;" & ASCII.LF
                 & "      end if;" & ASCII.LF
                 & "      In_C_Rdy := True;" & ASCII.LF
                 & "      loop" & ASCII.LF
                 & "         Aegir_User.CLI.Get_Line (S, L, E);" & ASCII.LF
                 & "         exit when E;" & ASCII.LF
                 & "         exit when In_C_Len + L + 2 > 4096;" & ASCII.LF
                 & "         for I in 1 .. L loop" & ASCII.LF
                 & "            In_C_Len := In_C_Len + 1;" & ASCII.LF
                 & "            In_C_Buf (In_C_Len) := S (I);" & ASCII.LF
                 & "         end loop;" & ASCII.LF
                 & "         In_C_Len := In_C_Len + 1;" & ASCII.LF
                 & "         In_C_Buf (In_C_Len) := ASCII.LF;" & ASCII.LF
                 & "      end loop;" & ASCII.LF
                 & "   end O2c_In_Cload;" & ASCII.LF
                 & "   function O2c_In_Avail return Integer is" & ASCII.LF
                 & "   begin" & ASCII.LF
                 & "      O2c_In_Cload;" & ASCII.LF
                 & "      return Integer (In_C_Len - In_C_Pos + 1);" & ASCII.LF
                 & "   end O2c_In_Avail;" & ASCII.LF
                 & "   function O2c_In_ReadCh return Character is" & ASCII.LF
                 & "      C : Character;" & ASCII.LF
                 & "   begin" & ASCII.LF
                 & "      O2c_In_Cload;" & ASCII.LF
                 & "      if In_C_Pos > In_C_Len then" & ASCII.LF
                 & "         return Character'Val (0);" & ASCII.LF
                 & "      end if;" & ASCII.LF
                 & "      C := In_C_Buf (In_C_Pos);" & ASCII.LF
                 & "      In_C_Pos := In_C_Pos + 1;" & ASCII.LF
                 & "      return C;" & ASCII.LF
                 & "   end O2c_In_ReadCh;" & ASCII.LF
                 & "   function O2c_In_Time return Long_Integer is" & ASCII.LF
                 & "      use type Aegir_User.Syscalls.U64;" & ASCII.LF
                 & "      Sec, Ns : Aegir_User.Syscalls.U64;" & ASCII.LF
                 & "   begin" & ASCII.LF
                 & "      Aegir_User.Syscalls.Read_Clock (Sec, Ns);" & ASCII.LF
                 & "      return Long_Integer (Sec) * 1000 + Long_Integer (Ns / 1000000);" & ASCII.LF
                 & "   end O2c_In_Time;" & ASCII.LF
                 & "";
            end if;
            if To_String (Mod_Name) = "XYplane" then
               --  M49 FFI: the Oakwood XYplane drawing plane lives in
               --  the module body as a byte array (640x400 plane
               --  limits); Key drains stdin like the Input module.
               S := S
                 & "   use type Interfaces.Unsigned_8;" & ASCII.LF
                 & "   Plane_W : Natural := 0;" & ASCII.LF
                 & "   Plane_H : Natural := 0;" & ASCII.LF
                 & "   Plane_Max : constant := 640 * 400;" & ASCII.LF
                 & "   Plane : array (0 .. Plane_Max - 1) of Interfaces.Unsigned_8 :=" & ASCII.LF
                 & "     (others => 0);" & ASCII.LF
                 & "   procedure O2c_Plane_Open (W : Integer; H : Integer) is" & ASCII.LF
                 & "   begin" & ASCII.LF
                 & "      if W > 0 and then H > 0 and then W * H <= Plane_Max then" & ASCII.LF
                 & "         Plane_W := W;" & ASCII.LF
                 & "         Plane_H := H;" & ASCII.LF
                 & "      else" & ASCII.LF
                 & "         Plane_W := 0;" & ASCII.LF
                 & "         Plane_H := 0;" & ASCII.LF
                 & "      end if;" & ASCII.LF
                 & "      Plane := (others => 0);" & ASCII.LF
                 & "   end O2c_Plane_Open;" & ASCII.LF
                 & "   procedure O2c_Plane_Clear is" & ASCII.LF
                 & "   begin" & ASCII.LF
                 & "      Plane := (others => 0);" & ASCII.LF
                 & "   end O2c_Plane_Clear;" & ASCII.LF
                 & "   procedure O2c_Plane_Dot (X : Integer; Y : Integer; Mode : Integer) is" & ASCII.LF
                 & "      Idx : Integer;" & ASCII.LF
                 & "   begin" & ASCII.LF
                 & "      if Plane_W = 0 or else X < 0 or else Y < 0" & ASCII.LF
                 & "        or else X >= Plane_W or else Y >= Plane_H" & ASCII.LF
                 & "      then" & ASCII.LF
                 & "         return;" & ASCII.LF
                 & "      end if;" & ASCII.LF
                 & "      Idx := Y * Plane_W + X;" & ASCII.LF
                 & "      if Mode = 0 then" & ASCII.LF
                 & "         Plane (Idx) := 0;" & ASCII.LF
                 & "      else" & ASCII.LF
                 & "         Plane (Idx) := 1;" & ASCII.LF
                 & "      end if;" & ASCII.LF
                 & "   end O2c_Plane_Dot;" & ASCII.LF
                 & "   function O2c_Plane_IsDot (X : Integer; Y : Integer) return Boolean is" & ASCII.LF
                 & "      Idx : Integer;" & ASCII.LF
                 & "   begin" & ASCII.LF
                 & "      if Plane_W = 0 or else X < 0 or else Y < 0" & ASCII.LF
                 & "        or else X >= Plane_W or else Y >= Plane_H" & ASCII.LF
                 & "      then" & ASCII.LF
                 & "         return False;" & ASCII.LF
                 & "      end if;" & ASCII.LF
                 & "      Idx := Y * Plane_W + X;" & ASCII.LF
                 & "      return Plane (Idx) /= 0;" & ASCII.LF
                 & "   end O2c_Plane_IsDot;" & ASCII.LF
                 & "   Key_Buf : String (1 .. 4096);" & ASCII.LF
                 & "   Key_Len : Natural := 0;" & ASCII.LF
                 & "   Key_Pos : Natural := 1;" & ASCII.LF
                 & "   Key_Rdy : Boolean := False;" & ASCII.LF
                 & "   procedure O2c_Key_Load is" & ASCII.LF
                 & "      S : String (1 .. 512);" & ASCII.LF
                 & "      L : Natural;" & ASCII.LF
                 & "      E : Boolean;" & ASCII.LF
                 & "   begin" & ASCII.LF
                 & "      Aegir_User.CLI.Init;" & ASCII.LF
                 & "      if Key_Rdy then" & ASCII.LF
                 & "         return;" & ASCII.LF
                 & "      end if;" & ASCII.LF
                 & "      Key_Rdy := True;" & ASCII.LF
                 & "      loop" & ASCII.LF
                 & "         Aegir_User.CLI.Get_Line (S, L, E);" & ASCII.LF
                 & "         exit when E;" & ASCII.LF
                 & "         exit when Key_Len + L + 2 > 4096;" & ASCII.LF
                 & "         for I in 1 .. L loop" & ASCII.LF
                 & "            Key_Len := Key_Len + 1;" & ASCII.LF
                 & "            Key_Buf (Key_Len) := S (I);" & ASCII.LF
                 & "         end loop;" & ASCII.LF
                 & "         Key_Len := Key_Len + 1;" & ASCII.LF
                 & "         Key_Buf (Key_Len) := ASCII.LF;" & ASCII.LF
                 & "      end loop;" & ASCII.LF
                 & "   end O2c_Key_Load;" & ASCII.LF
                 & "   function O2c_Plane_Key return Character is" & ASCII.LF
                 & "      C : Character;" & ASCII.LF
                 & "   begin" & ASCII.LF
                 & "      O2c_Key_Load;" & ASCII.LF
                 & "      if Key_Pos > Key_Len then" & ASCII.LF
                 & "         return Character'Val (0);   --  no keyboard in this ABI" & ASCII.LF
                 & "      end if;" & ASCII.LF
                 & "      C := Key_Buf (Key_Pos);" & ASCII.LF
                 & "      Key_Pos := Key_Pos + 1;" & ASCII.LF
                 & "      return C;" & ASCII.LF
                 & "   end O2c_Plane_Key;" & ASCII.LF
                 & "";
            end if;
            if To_String (Mod_Name) = "Args" then
               --  M50 FFI: command-line arguments (builtin Args only).
               --  aegir's args page has no argv[0]: Argument (1) is the
               --  first argument, so our Get is 1-based (OBNC's
               --  extArgs.Get is 0-based for the same list).
               S := S
                 & "   function O2c_Arg_Count return Integer is" & ASCII.LF
                 & "   begin" & ASCII.LF
                 & "      Aegir_User.CLI.Init;" & ASCII.LF
                 & "      return Integer (Aegir_User.CLI.Arg_Count);" & ASCII.LF
                 & "   end O2c_Arg_Count;" & ASCII.LF
                 & "   procedure O2c_Arg_Get (N : Integer; Buf : out String; Res : out Integer) is" & ASCII.LF
                 & "      S : String (1 .. 256);" & ASCII.LF
                 & "      L : Natural := 0;" & ASCII.LF
                 & "   begin" & ASCII.LF
                 & "      Aegir_User.CLI.Init;" & ASCII.LF
                 & "      if N < 1 or else N > Aegir_User.CLI.Arg_Count then" & ASCII.LF
                 & "         Res := -1;" & ASCII.LF
                 & "      else" & ASCII.LF
                 & "         declare" & ASCII.LF
                 & "            A : constant String := Aegir_User.CLI.Argument (Positive (N));" & ASCII.LF
                 & "         begin" & ASCII.LF
                 & "            for I in A'Range loop" & ASCII.LF
                 & "               exit when L >= 256;" & ASCII.LF
                 & "               L := L + 1;" & ASCII.LF
                 & "               S (L) := A (I);" & ASCII.LF
                 & "            end loop;" & ASCII.LF
                 & "            Res := L;" & ASCII.LF
                 & "         end;" & ASCII.LF
                 & "      end if;" & ASCII.LF
                 & "      for I in 1 .. Buf'Length loop" & ASCII.LF
                 & "         if I <= L then" & ASCII.LF
                 & "            Buf (Buf'First + I - 1) := S (I);" & ASCII.LF
                 & "         else" & ASCII.LF
                 & "            Buf (Buf'First + I - 1) := Character'Val (0);" & ASCII.LF
                 & "         end if;" & ASCII.LF
                 & "      end loop;" & ASCII.LF
                 & "   end O2c_Arg_Get;" & ASCII.LF
                 & "";
            end if;
            if To_String (Mod_Name) = "Env" then
               --  M51 FFI: environment variables (builtin Env only).
               --  aegir keeps them as ENV:<Name> files, global by
               --  construction; Get answers "" for an unset name.
               S := S
                 & "   procedure O2c_Env_Get (Name : String; Value : out String) is" & ASCII.LF
                 & "      V : constant String := Aegir_User.CLI.Get_Env (Name);" & ASCII.LF
                 & "      L : constant Natural :=" & ASCII.LF
                 & "        (if V'Length < Value'Length then V'Length else Value'Length);" & ASCII.LF
                 & "   begin" & ASCII.LF
                 & "      for I in 1 .. L loop" & ASCII.LF
                 & "         Value (Value'First + I - 1) := V (V'First + I - 1);" & ASCII.LF
                 & "      end loop;" & ASCII.LF
                 & "      for I in L + 1 .. Value'Length loop" & ASCII.LF
                 & "         Value (Value'First + I - 1) := Character'Val (0);" & ASCII.LF
                 & "      end loop;" & ASCII.LF
                 & "   end O2c_Env_Get;" & ASCII.LF
                 & "   procedure O2c_Env_Set (Name : String; Value : String) is" & ASCII.LF
                 & "      use type Aegir_User.CLI.U64;" & ASCII.LF
                 & "      St : Aegir_User.CLI.U64;" & ASCII.LF
                 & "   begin" & ASCII.LF
                 & "      St := Aegir_User.CLI.Set_Env (Name, Value);" & ASCII.LF
                 & "      if St = 0 then" & ASCII.LF
                 & "         return;                  --  Status_Ok" & ASCII.LF
                 & "      end if;" & ASCII.LF
                 & "   end O2c_Env_Set;" & ASCII.LF
                 & "";
            end if;
            if To_String (Mod_Name) = "Convert" then
               --  M52 FFI: number <-> string (builtin Convert only).
               --  ToInt/ToReal report 0 on success and -1 when the
               --  text holds no number; FromInt renders via 'Image.
               S := S
                 & "   procedure O2c_Conv_ToInt (S : String; X : out Integer; Res : out Integer)" & ASCII.LF
                 & "   is" & ASCII.LF
                 & "      V : Integer := 0;" & ASCII.LF
                 & "      Neg : Boolean := False;" & ASCII.LF
                 & "      Seen : Boolean := False;" & ASCII.LF
                 & "      K : Natural := 1;" & ASCII.LF
                 & "   begin" & ASCII.LF
                 & "      while K <= S'Length and then S (S'First + K - 1) = ' ' loop" & ASCII.LF
                 & "         K := K + 1;" & ASCII.LF
                 & "      end loop;" & ASCII.LF
                 & "      if K <= S'Length and then S (S'First + K - 1) = '-' then" & ASCII.LF
                 & "         Neg := True;" & ASCII.LF
                 & "         K := K + 1;" & ASCII.LF
                 & "      elsif K <= S'Length and then S (S'First + K - 1) = '+' then" & ASCII.LF
                 & "         K := K + 1;" & ASCII.LF
                 & "      end if;" & ASCII.LF
                 & "      while K <= S'Length and then S (S'First + K - 1) in '0' .. '9' loop" & ASCII.LF
                 & "         V := V * 10" & ASCII.LF
                 & "           + (Character'Pos (S (S'First + K - 1)) - Character'Pos ('0'));" & ASCII.LF
                 & "         Seen := True;" & ASCII.LF
                 & "         K := K + 1;" & ASCII.LF
                 & "      end loop;" & ASCII.LF
                 & "      if Seen then" & ASCII.LF
                 & "         if Neg then" & ASCII.LF
                 & "            X := -V;" & ASCII.LF
                 & "         else" & ASCII.LF
                 & "            X := V;" & ASCII.LF
                 & "         end if;" & ASCII.LF
                 & "         Res := 0;" & ASCII.LF
                 & "      else" & ASCII.LF
                 & "         X := 0;" & ASCII.LF
                 & "         Res := -1;" & ASCII.LF
                 & "      end if;" & ASCII.LF
                 & "   end O2c_Conv_ToInt;" & ASCII.LF
                 & "   procedure O2c_Conv_ToReal (S : String; X : out Float;" & ASCII.LF
                 & "                              Res : out Integer) is" & ASCII.LF
                 & "      V : Float := 0.0;" & ASCII.LF
                 & "      Frac : Float := 0.1;" & ASCII.LF
                 & "      Neg : Boolean := False;" & ASCII.LF
                 & "      Dot : Boolean := False;" & ASCII.LF
                 & "      Seen : Boolean := False;" & ASCII.LF
                 & "      K : Natural := 1;" & ASCII.LF
                 & "   begin" & ASCII.LF
                 & "      while K <= S'Length and then S (S'First + K - 1) = ' ' loop" & ASCII.LF
                 & "         K := K + 1;" & ASCII.LF
                 & "      end loop;" & ASCII.LF
                 & "      if K <= S'Length and then S (S'First + K - 1) = '-' then" & ASCII.LF
                 & "         Neg := True;" & ASCII.LF
                 & "         K := K + 1;" & ASCII.LF
                 & "      elsif K <= S'Length and then S (S'First + K - 1) = '+' then" & ASCII.LF
                 & "         K := K + 1;" & ASCII.LF
                 & "      end if;" & ASCII.LF
                 & "      loop" & ASCII.LF
                 & "         exit when K > S'Length;" & ASCII.LF
                 & "         declare" & ASCII.LF
                 & "            C : constant Character := S (S'First + K - 1);" & ASCII.LF
                 & "         begin" & ASCII.LF
                 & "            if C in '0' .. '9' then" & ASCII.LF
                 & "               Seen := True;" & ASCII.LF
                 & "               if Dot then" & ASCII.LF
                 & "                  V := V + Float (Character'Pos (C) - Character'Pos ('0'))" & ASCII.LF
                 & "                    * Frac;" & ASCII.LF
                 & "                  Frac := Frac / 10.0;" & ASCII.LF
                 & "               else" & ASCII.LF
                 & "                  V := V * 10.0" & ASCII.LF
                 & "                    + Float (Character'Pos (C) - Character'Pos ('0'));" & ASCII.LF
                 & "               end if;" & ASCII.LF
                 & "               K := K + 1;" & ASCII.LF
                 & "            elsif C = '.' and then not Dot then" & ASCII.LF
                 & "               Dot := True;" & ASCII.LF
                 & "               K := K + 1;" & ASCII.LF
                 & "            else" & ASCII.LF
                 & "               exit;" & ASCII.LF
                 & "            end if;" & ASCII.LF
                 & "         end;" & ASCII.LF
                 & "      end loop;" & ASCII.LF
                 & "      if Seen then" & ASCII.LF
                 & "         if Neg then" & ASCII.LF
                 & "            X := -V;" & ASCII.LF
                 & "         else" & ASCII.LF
                 & "            X := V;" & ASCII.LF
                 & "         end if;" & ASCII.LF
                 & "         Res := 0;" & ASCII.LF
                 & "      else" & ASCII.LF
                 & "         X := 0.0;" & ASCII.LF
                 & "         Res := -1;" & ASCII.LF
                 & "      end if;" & ASCII.LF
                 & "   end O2c_Conv_ToReal;" & ASCII.LF
                 & "   procedure O2c_Conv_FromInt (X : Integer; S : out String) is" & ASCII.LF
                 & "      Img : constant String := Integer'Image (X);" & ASCII.LF
                 & "      L : Natural := 0;" & ASCII.LF
                 & "   begin" & ASCII.LF
                 & "      for I in Img'Range loop" & ASCII.LF
                 & "         if not (L = 0 and then Img (I) = ' ') then" & ASCII.LF
                 & "            L := L + 1;" & ASCII.LF
                 & "            if L <= S'Length then" & ASCII.LF
                 & "               S (S'First + L - 1) := Img (I);" & ASCII.LF
                 & "            end if;" & ASCII.LF
                 & "         end if;" & ASCII.LF
                 & "      end loop;" & ASCII.LF
                 & "      if L > S'Length then" & ASCII.LF
                 & "         L := S'Length;" & ASCII.LF
                 & "      end if;" & ASCII.LF
                 & "      for I in L + 1 .. S'Length loop" & ASCII.LF
                 & "         S (S'First + I - 1) := Character'Val (0);" & ASCII.LF
                 & "      end loop;" & ASCII.LF
                 & "   end O2c_Conv_FromInt;" & ASCII.LF
                 & "";
            end if;
            if To_String (Mod_Name) = "Reals" then
               --  M46 FFI: string -> REAL (ConvertTo only; the
               --  REAL -> string direction is pure Oberon).
               S := S
                 & "   function O2c_StrToReal (Buf : String) return Float is" & ASCII.LF
                 & "      V : Float := 0.0;" & ASCII.LF
                 & "      Frac : Float := 0.1;" & ASCII.LF
                 & "      Neg : Boolean := False;" & ASCII.LF
                 & "      Dot : Boolean := False;" & ASCII.LF
                 & "      Seen : Boolean := False;" & ASCII.LF
                 & "      K : Natural := 1;" & ASCII.LF
                 & "      Exp : Integer := 0;" & ASCII.LF
                 & "      Exp_Neg : Boolean := False;" & ASCII.LF
                 & "   begin" & ASCII.LF
                 & "      while K <= Buf'Length" & ASCII.LF
                 & "        and then Buf (Buf'First + K - 1) = ' ' loop" & ASCII.LF
                 & "         K := K + 1;" & ASCII.LF
                 & "      end loop;" & ASCII.LF
                 & "      if K <= Buf'Length and then Buf (Buf'First + K - 1) = '-' then" & ASCII.LF
                 & "         Neg := True;" & ASCII.LF
                 & "         K := K + 1;" & ASCII.LF
                 & "      elsif K <= Buf'Length and then Buf (Buf'First + K - 1) = '+' then" & ASCII.LF
                 & "         K := K + 1;" & ASCII.LF
                 & "      end if;" & ASCII.LF
                 & "      loop" & ASCII.LF
                 & "         exit when K > Buf'Length;" & ASCII.LF
                 & "         declare" & ASCII.LF
                 & "            C : constant Character := Buf (Buf'First + K - 1);" & ASCII.LF
                 & "         begin" & ASCII.LF
                 & "            if C in '0' .. '9' then" & ASCII.LF
                 & "               Seen := True;" & ASCII.LF
                 & "               if Dot then" & ASCII.LF
                 & "                  V := V + Float (Character'Pos (C) - Character'Pos ('0'))" & ASCII.LF
                 & "                    * Frac;" & ASCII.LF
                 & "                  Frac := Frac / 10.0;" & ASCII.LF
                 & "               else" & ASCII.LF
                 & "                  V := V * 10.0" & ASCII.LF
                 & "                    + Float (Character'Pos (C) - Character'Pos ('0'));" & ASCII.LF
                 & "               end if;" & ASCII.LF
                 & "               K := K + 1;" & ASCII.LF
                 & "            elsif C = '.' and then not Dot then" & ASCII.LF
                 & "               Dot := True;" & ASCII.LF
                 & "               K := K + 1;" & ASCII.LF
                 & "            elsif C = 'e' or else C = 'E' then" & ASCII.LF
                 & "               K := K + 1;" & ASCII.LF
                 & "               if K <= Buf'Length" & ASCII.LF
                 & "                 and then Buf (Buf'First + K - 1) = '-' then" & ASCII.LF
                 & "                  Exp_Neg := True;" & ASCII.LF
                 & "                  K := K + 1;" & ASCII.LF
                 & "               elsif K <= Buf'Length" & ASCII.LF
                 & "                 and then Buf (Buf'First + K - 1) = '+' then" & ASCII.LF
                 & "                  K := K + 1;" & ASCII.LF
                 & "               end if;" & ASCII.LF
                 & "               while K <= Buf'Length" & ASCII.LF
                 & "                 and then Buf (Buf'First + K - 1) in '0' .. '9' loop" & ASCII.LF
                 & "                  Exp := Exp * 10" & ASCII.LF
                 & "                    + (Character'Pos (Buf (Buf'First + K - 1))" & ASCII.LF
                 & "                       - Character'Pos ('0'));" & ASCII.LF
                 & "                  K := K + 1;" & ASCII.LF
                 & "               end loop;" & ASCII.LF
                 & "               exit;" & ASCII.LF
                 & "            else" & ASCII.LF
                 & "               exit;" & ASCII.LF
                 & "            end if;" & ASCII.LF
                 & "         end;" & ASCII.LF
                 & "      end loop;" & ASCII.LF
                 & "      if not Seen then" & ASCII.LF
                 & "         return 0.0;" & ASCII.LF
                 & "      end if;" & ASCII.LF
                 & "      for I in 1 .. Exp loop" & ASCII.LF
                 & "         if Exp_Neg then" & ASCII.LF
                 & "            V := V / 10.0;" & ASCII.LF
                 & "         else" & ASCII.LF
                 & "            V := V * 10.0;" & ASCII.LF
                 & "         end if;" & ASCII.LF
                 & "      end loop;" & ASCII.LF
                 & "      if Neg then" & ASCII.LF
                 & "         return -V;" & ASCII.LF
                 & "      end if;" & ASCII.LF
                 & "      return V;" & ASCII.LF
                 & "   end O2c_StrToReal;" & ASCII.LF
                 & "";
            end if;
            S := S & To_String (Decl_Buf);
            if Length (Body_Buf) > 0 then
               S := S & "begin" & ASCII.LF;
               if Used_Console then
                  S := S & "   Aegir_User.Console.Set_Endpoint (1);"
                    & ASCII.LF;
               end if;
               S := S & To_String (Body_Buf);
            end if;
            S := S & "end " & Ada_Id (To_String (Mod_Name)) & ";"
              & ASCII.LF;
            if Length (Decl_Buf) = 0 and then Length (Body_Buf) = 0 then
               Body_Txt := Null_Unbounded_String;   --  spec-only library
            else
               Body_Txt := S;
            end if;
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

   --  Oakwood builtin libraries embedded in the compiler (M38):
   --  auto-provided to every multi-module build so that any module can
   --  simply 'import Strings;' without staging a source file.
   function Oak_Strings_Src return String is
      S : Unbounded_String;
   begin
      S := S & "module Strings;" & ASCII.LF
        & "procedure Length*(s: array of char): integer;" & ASCII.LF
        & "  var i, n: integer;" & ASCII.LF
        & "begin" & ASCII.LF
        & "  n := 0;" & ASCII.LF
        & "  for i := 0 to len(s) - 1 do" & ASCII.LF
        & "    if s[i] = CHR(0) then" & ASCII.LF
        & "      return n" & ASCII.LF
        & "    end;" & ASCII.LF
        & "    n := n + 1" & ASCII.LF
        & "  end;" & ASCII.LF
        & "  return n" & ASCII.LF
        & "end Length;" & ASCII.LF
        & "procedure Pos*(sub: array of char; s: array of char): integer;" & ASCII.LF
        & "  var i, j, sl, sul, bad: integer;" & ASCII.LF
        & "begin" & ASCII.LF
        & "  sl := Length(s);" & ASCII.LF
        & "  sul := Length(sub);" & ASCII.LF
        & "  if sul = 0 then" & ASCII.LF
        & "    return 0" & ASCII.LF
        & "  end;" & ASCII.LF
        & "  if sul > sl then" & ASCII.LF
        & "    return -1" & ASCII.LF
        & "  end;" & ASCII.LF
        & "  for i := 0 to sl - sul do" & ASCII.LF
        & "    j := 0;" & ASCII.LF
        & "    bad := 0;" & ASCII.LF
        & "    while (j < sul) & (bad = 0) do" & ASCII.LF
        & "      if s[i + j] # sub[j] then" & ASCII.LF
        & "        bad := 1" & ASCII.LF
        & "      else" & ASCII.LF
        & "        j := j + 1" & ASCII.LF
        & "      end" & ASCII.LF
        & "    end;" & ASCII.LF
        & "    if (bad = 0) & (j = sul) then" & ASCII.LF
        & "      return i" & ASCII.LF
        & "    end" & ASCII.LF
        & "  end;" & ASCII.LF
        & "  return -1" & ASCII.LF
        & "end Pos;" & ASCII.LF
        & "procedure Cap*(var s: array of char);" & ASCII.LF
        & "  var i, n: integer;" & ASCII.LF
        & "begin" & ASCII.LF
        & "  n := Length(s);" & ASCII.LF
        & "  for i := 0 to n - 1 do" & ASCII.LF
        & "    if (ORD(s[i]) >= 97) & (ORD(s[i]) <= 122) then" & ASCII.LF
        & "      s[i] := CHR(ORD(s[i]) - 32)" & ASCII.LF
        & "    end" & ASCII.LF
        & "  end" & ASCII.LF
        & "end Cap;" & ASCII.LF
        & "procedure Delete*(var s: array of char; i: integer; n: integer);" & ASCII.LF
        & "  var j, sl, a, c: integer;" & ASCII.LF
        & "begin" & ASCII.LF
        & "  sl := Length(s);" & ASCII.LF
        & "  a := i;" & ASCII.LF
        & "  c := n;" & ASCII.LF
        & "  if a < 0 then a := 0 end;" & ASCII.LF
        & "  if c < 0 then c := 0 end;" & ASCII.LF
        & "  if a >= sl then return end;" & ASCII.LF
        & "  if a + c > sl then c := sl - a end;" & ASCII.LF
        & "  j := a;" & ASCII.LF
        & "  while j + c < sl do" & ASCII.LF
        & "    s[j] := s[j + c];" & ASCII.LF
        & "    j := j + 1" & ASCII.LF
        & "  end;" & ASCII.LF
        & "  while j < sl do" & ASCII.LF
        & "    s[j] := CHR(0);" & ASCII.LF
        & "    j := j + 1" & ASCII.LF
        & "  end" & ASCII.LF
        & "end Delete;" & ASCII.LF
        & "end Strings." & ASCII.LF
        & "" & ASCII.LF;
      return To_String (S);
   end Oak_Strings_Src;

   --  M39: ETH-style Texts subset (console-backed Writer API; no
   --  Text/Buffer/Log objects yet), embedded as a builtin module.
   function Oak_Texts_Src return String is
      S : Unbounded_String;
   begin
      S := S & "module Texts;" & ASCII.LF
        & "import Out;" & ASCII.LF
        & "type Writer* = record pos: integer end;" & ASCII.LF
        & "type C2 = array 2 of char;" & ASCII.LF
        & "procedure OpenWriter*(var w: Writer);" & ASCII.LF
        & "begin" & ASCII.LF
        & "  w.pos := 0" & ASCII.LF
        & "end OpenWriter;" & ASCII.LF
        & "procedure Write*(var w: Writer; ch: char);" & ASCII.LF
        & "  var t: C2;" & ASCII.LF
        & "begin" & ASCII.LF
        & "  t[0] := ch;" & ASCII.LF
        & "  t[1] := CHR(0);" & ASCII.LF
        & "  Out.String(t)" & ASCII.LF
        & "end Write;" & ASCII.LF
        & "procedure WriteString*(var w: Writer; s: array of char);" & ASCII.LF
        & "begin" & ASCII.LF
        & "  Out.String(s)" & ASCII.LF
        & "end WriteString;" & ASCII.LF
        & "procedure WriteLn*(var w: Writer);" & ASCII.LF
        & "begin" & ASCII.LF
        & "  Out.Ln" & ASCII.LF
        & "end WriteLn;" & ASCII.LF
        & "procedure WriteInt*(var w: Writer; x: integer; n: integer);" & ASCII.LF
        & "begin" & ASCII.LF
        & "  Out.Int(x, 0)" & ASCII.LF
        & "end WriteInt;" & ASCII.LF
        & "procedure WriteReal*(var w: Writer; r: real; n: integer);" & ASCII.LF
        & "begin" & ASCII.LF
        & "  Out.Real(r, 0)" & ASCII.LF
        & "end WriteReal;" & ASCII.LF
        & "end Texts." & ASCII.LF
        & "" & ASCII.LF ;
      return To_String (S);
   end Oak_Texts_Src;

   function Oak_Files_Src return String is
      S : Unbounded_String;
   begin
      S := S & "module Files;" & ASCII.LF;
      S := S & "type A64* = array 64 of char;" & ASCII.LF;
      S := S & "type A1* = array 1 of char;" & ASCII.LF;
      S := S & "type File* = pointer to FileDesc;" & ASCII.LF;
      S := S & "type FileDesc = record name: A64; size: longint end;" & ASCII.LF;
      S := S & "type Rider* = record f: File; pos: longint; eof*: boolean; res*: integer; cur: A1 end;" & ASCII.LF;
      S := S & "procedure Old*(name: array of char): File;" & ASCII.LF;
      S := S & "  var i: integer; f: File;" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  new(f);" & ASCII.LF;
      S := S & "  f^.size := FStat(name);" & ASCII.LF;
      S := S & "  i := 0;" & ASCII.LF;
      S := S & "  while i < 64 do" & ASCII.LF;
      S := S & "    if i < len(name) then" & ASCII.LF;
      S := S & "      f^.name[i] := name[i]" & ASCII.LF;
      S := S & "    else" & ASCII.LF;
      S := S & "      f^.name[i] := CHR(0)" & ASCII.LF;
      S := S & "    end;" & ASCII.LF;
      S := S & "    i := i + 1" & ASCII.LF;
      S := S & "  end;" & ASCII.LF;
      S := S & "  return f" & ASCII.LF;
      S := S & "end Old;" & ASCII.LF;
      S := S & "procedure New*(name: array of char): File;" & ASCII.LF;
      S := S & "  var i: integer; f: File;" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  new(f);" & ASCII.LF;
      S := S & "  f^.size := 0;" & ASCII.LF;
      S := S & "  i := 0;" & ASCII.LF;
      S := S & "  while i < 64 do" & ASCII.LF;
      S := S & "    if i < len(name) then" & ASCII.LF;
      S := S & "      f^.name[i] := name[i]" & ASCII.LF;
      S := S & "    else" & ASCII.LF;
      S := S & "      f^.name[i] := CHR(0)" & ASCII.LF;
      S := S & "    end;" & ASCII.LF;
      S := S & "    i := i + 1" & ASCII.LF;
      S := S & "  end;" & ASCII.LF;
      S := S & "  return f" & ASCII.LF;
      S := S & "end New;" & ASCII.LF;
      S := S & "procedure Length*(f: File): longint;" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  return f^.size" & ASCII.LF;
      S := S & "end Length;" & ASCII.LF;
      S := S & "procedure Register*(f: File);" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "end Register;" & ASCII.LF;
      S := S & "procedure Open*(var r: Rider; f: File);" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  r.f := f;" & ASCII.LF;
      S := S & "  r.pos := 0;" & ASCII.LF;
      S := S & "  r.eof := false;" & ASCII.LF;
      S := S & "  r.res := 0" & ASCII.LF;
      S := S & "end Open;" & ASCII.LF;
      S := S & "procedure Base*(var r: Rider): File;" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  return r.f" & ASCII.LF;
      S := S & "end Base;" & ASCII.LF;
      S := S & "procedure Seek*(var r: Rider; pos: longint);" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  r.pos := pos;" & ASCII.LF;
      S := S & "  r.eof := false" & ASCII.LF;
      S := S & "end Seek;" & ASCII.LF;
      S := S & "procedure Pos*(var r: Rider): longint;" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  return r.pos" & ASCII.LF;
      S := S & "end Pos;" & ASCII.LF;
      S := S & "procedure Read*(var r: Rider; var ch: char);" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  if r.eof then" & ASCII.LF;
      S := S & "    return" & ASCII.LF;
      S := S & "  end;" & ASCII.LF;
      S := S & "  if r.pos >= r.f^.size then" & ASCII.LF;
      S := S & "    r.eof := true;" & ASCII.LF;
      S := S & "    return" & ASCII.LF;
      S := S & "  end;" & ASCII.LF;
      S := S & "  r.res := FRead(r.f^.name, r.pos, r.cur);" & ASCII.LF;
      S := S & "  ch := r.cur[0];" & ASCII.LF;
      S := S & "  r.pos := r.pos + 1" & ASCII.LF;
      S := S & "end Read;" & ASCII.LF;
      S := S & "procedure Close*(var r: Rider);" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  r.res := FClose(r.f^.name)" & ASCII.LF;
      S := S & "end Close;" & ASCII.LF;
      S := S & "procedure Set*(var r: Rider; f: File; pos: longint);" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  r.f := f;" & ASCII.LF;
      S := S & "  r.pos := pos;" & ASCII.LF;
      S := S & "  r.eof := false;" & ASCII.LF;
      S := S & "  r.res := 0" & ASCII.LF;
      S := S & "end Set;" & ASCII.LF;
      S := S & "procedure Rename*(from: array of char; dst: array of char);" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  FRename(from, dst)" & ASCII.LF;
      S := S & "end Rename;" & ASCII.LF;
      S := S & "procedure Delete*(name: array of char);" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  FDel(name)" & ASCII.LF;
      S := S & "end Delete;" & ASCII.LF;
      S := S & "procedure Write*(var r: Rider; ch: char);" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  r.cur[0] := ch;" & ASCII.LF;
      S := S & "  r.res := FWrite(r.f^.name, r.pos, r.cur);" & ASCII.LF;
      S := S & "  r.pos := r.pos + 1" & ASCII.LF;
      S := S & "end Write;" & ASCII.LF;
      S := S & "procedure WriteString*(var r: Rider; s: array of char);" & ASCII.LF;
      S := S & "  var i: integer;" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  for i := 0 to len(s) - 1 do" & ASCII.LF;
      S := S & "    if s[i] = CHR(0) then" & ASCII.LF;
      S := S & "      return" & ASCII.LF;
      S := S & "    end;" & ASCII.LF;
      S := S & "    r.cur[0] := s[i];" & ASCII.LF;
      S := S & "    r.res := FWrite(r.f^.name, r.pos, r.cur);" & ASCII.LF;
      S := S & "    r.pos := r.pos + 1" & ASCII.LF;
      S := S & "  end" & ASCII.LF;
      S := S & "end WriteString;" & ASCII.LF;
      S := S & "procedure Wait*(path: array of char);" & ASCII.LF;
      S := S & "  var i, j: integer;" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  i := 0;" & ASCII.LF;
      S := S & "  while (i < 400) & (FStat(path) < 0) do" & ASCII.LF;
      S := S & "    j := 0;" & ASCII.LF;
      S := S & "    while j < 2000000 do" & ASCII.LF;
      S := S & "      j := j + 1" & ASCII.LF;
      S := S & "    end;" & ASCII.LF;
      S := S & "    i := i + 1" & ASCII.LF;
      S := S & "  end" & ASCII.LF;
      S := S & "end Wait;" & ASCII.LF;
      S := S & "end Files." & ASCII.LF;
      return To_String (S);
   end Oak_Files_Src;


   function Oak_Math_Src return String is
      S : Unbounded_String;
   begin
      S := S & "module Math;" & ASCII.LF;
      S := S & "const pi* = 3.14159265358979;" & ASCII.LF;
      S := S & "const e* = 2.71828182845905;" & ASCII.LF;
      S := S & "procedure power*(base: real; ex: real): real;" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  return Power(base, ex)" & ASCII.LF;
      S := S & "end power;" & ASCII.LF;
      S := S & "procedure exp*(x: real): real;" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  return Exp(x)" & ASCII.LF;
      S := S & "end exp;" & ASCII.LF;
      S := S & "procedure ln*(x: real): real;" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  return Ln(x)" & ASCII.LF;
      S := S & "end ln;" & ASCII.LF;
      S := S & "procedure log*(x: real; base: real): real;" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  return Log(x, base)" & ASCII.LF;
      S := S & "end log;" & ASCII.LF;
      S := S & "procedure sin*(x: real): real;" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  return Sin(x)" & ASCII.LF;
      S := S & "end sin;" & ASCII.LF;
      S := S & "procedure cos*(x: real): real;" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  return Cos(x)" & ASCII.LF;
      S := S & "end cos;" & ASCII.LF;
      S := S & "procedure tan*(x: real): real;" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  return Tan(x)" & ASCII.LF;
      S := S & "end tan;" & ASCII.LF;
      S := S & "procedure arcsin*(x: real): real;" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  return Arcsin(x)" & ASCII.LF;
      S := S & "end arcsin;" & ASCII.LF;
      S := S & "procedure arccos*(x: real): real;" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  return Arccos(x)" & ASCII.LF;
      S := S & "end arccos;" & ASCII.LF;
      S := S & "procedure arctan*(x: real): real;" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  return Arctan(x)" & ASCII.LF;
      S := S & "end arctan;" & ASCII.LF;
      S := S & "procedure arctan2*(y: real; x: real): real;" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  return Arctan2(y, x)" & ASCII.LF;
      S := S & "end arctan2;" & ASCII.LF;
      S := S & "end Math." & ASCII.LF;
      S := S & "" & ASCII.LF;
      return To_String (S);
   end Oak_Math_Src;

   function Oak_In_Src return String is
      S : Unbounded_String;
   begin
      S := S & "module In;" & ASCII.LF;
      S := S & "var Done*: boolean;" & ASCII.LF;
      S := S & "procedure Open*;" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  InOpen" & ASCII.LF;
      S := S & "end Open;" & ASCII.LF;
      S := S & "procedure Char*(var ch: char);" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  ch := InChar()" & ASCII.LF;
      S := S & "end Char;" & ASCII.LF;
      S := S & "procedure Int*(var x: integer);" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  x := InInt()" & ASCII.LF;
      S := S & "end Int;" & ASCII.LF;
      S := S & "procedure LongInt*(var x: longint);" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  x := InLong()" & ASCII.LF;
      S := S & "end LongInt;" & ASCII.LF;
      S := S & "procedure Real*(var x: real);" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  x := InReal()" & ASCII.LF;
      S := S & "end Real;" & ASCII.LF;
      S := S & "procedure String*(var str: array of char);" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  InString(str)" & ASCII.LF;
      S := S & "end String;" & ASCII.LF;
      S := S & "procedure Name*(var name: array of char);" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  InName(name)" & ASCII.LF;
      S := S & "end Name;" & ASCII.LF;
      S := S & "end In." & ASCII.LF;
      return To_String (S);
   end Oak_In_Src;


   function Oak_Term_Src return String is
      S : Unbounded_String;
   begin
      S := S & "module Term;" & ASCII.LF;
      S := S & "import Out;" & ASCII.LF;
      S := S & "const black = 0;" & ASCII.LF;
      S := S & "const red = 1;" & ASCII.LF;
      S := S & "const green = 2;" & ASCII.LF;
      S := S & "const yellow = 3;" & ASCII.LF;
      S := S & "const blue = 4;" & ASCII.LF;
      S := S & "const magenta = 5;" & ASCII.LF;
      S := S & "const cyan = 6;" & ASCII.LF;
      S := S & "const white = 7;" & ASCII.LF;
      S := S & "type A2 = array 2 of char;" & ASCII.LF;
      S := S & "type A3 = array 3 of char;" & ASCII.LF;
      S := S & "procedure Bracket*;" & ASCII.LF;
      S := S & "  var t: A3;" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  t[0] := CHR(27);" & ASCII.LF;
      S := S & "  t[1] := CHR(91);" & ASCII.LF;
      S := S & "  t[2] := CHR(0);" & ASCII.LF;
      S := S & "  Out.String(t)" & ASCII.LF;
      S := S & "end Bracket;" & ASCII.LF;
      S := S & "procedure Ch*(code: integer);" & ASCII.LF;
      S := S & "  var t: A2;" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  t[0] := CHR(code);" & ASCII.LF;
      S := S & "  t[1] := CHR(0);" & ASCII.LF;
      S := S & "  Out.String(t)" & ASCII.LF;
      S := S & "end Ch;" & ASCII.LF;
      S := S & "procedure Clear*;" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  Bracket;" & ASCII.LF;
      S := S & "  Ch(50);" & ASCII.LF;
      S := S & "  Ch(74)" & ASCII.LF;
      S := S & "end Clear;" & ASCII.LF;
      S := S & "procedure ClearLine*;" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  Bracket;" & ASCII.LF;
      S := S & "  Ch(50);" & ASCII.LF;
      S := S & "  Ch(75)" & ASCII.LF;
      S := S & "end ClearLine;" & ASCII.LF;
      S := S & "procedure Invert*;" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  Bracket;" & ASCII.LF;
      S := S & "  Ch(55);" & ASCII.LF;
      S := S & "  Ch(109)" & ASCII.LF;
      S := S & "end Invert;" & ASCII.LF;
      S := S & "procedure Reset*;" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  Bracket;" & ASCII.LF;
      S := S & "  Ch(48);" & ASCII.LF;
      S := S & "  Ch(109)" & ASCII.LF;
      S := S & "end Reset;" & ASCII.LF;
      S := S & "procedure SetColor*(fg: integer; bg: integer);" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  Bracket;" & ASCII.LF;
      S := S & "  Ch(51);" & ASCII.LF;
      S := S & "  Out.Int(fg, 0);" & ASCII.LF;
      S := S & "  Ch(109);" & ASCII.LF;
      S := S & "  Bracket;" & ASCII.LF;
      S := S & "  Ch(52);" & ASCII.LF;
      S := S & "  Out.Int(bg, 0);" & ASCII.LF;
      S := S & "  Ch(109)" & ASCII.LF;
      S := S & "end SetColor;" & ASCII.LF;
      S := S & "procedure SetCursor*(x: integer; y: integer);" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  Bracket;" & ASCII.LF;
      S := S & "  Out.Int(y + 1, 0);" & ASCII.LF;
      S := S & "  Ch(59);" & ASCII.LF;
      S := S & "  Out.Int(x + 1, 0);" & ASCII.LF;
      S := S & "  Ch(72)" & ASCII.LF;
      S := S & "end SetCursor;" & ASCII.LF;
      S := S & "procedure CursorUp*(n: integer);" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  Bracket;" & ASCII.LF;
      S := S & "  Out.Int(n, 0);" & ASCII.LF;
      S := S & "  Ch(65)" & ASCII.LF;
      S := S & "end CursorUp;" & ASCII.LF;
      S := S & "procedure CursorDown*(n: integer);" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  Bracket;" & ASCII.LF;
      S := S & "  Out.Int(n, 0);" & ASCII.LF;
      S := S & "  Ch(66)" & ASCII.LF;
      S := S & "end CursorDown;" & ASCII.LF;
      S := S & "procedure CursorRight*(n: integer);" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  Bracket;" & ASCII.LF;
      S := S & "  Out.Int(n, 0);" & ASCII.LF;
      S := S & "  Ch(67)" & ASCII.LF;
      S := S & "end CursorRight;" & ASCII.LF;
      S := S & "procedure CursorLeft*(n: integer);" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  Bracket;" & ASCII.LF;
      S := S & "  Out.Int(n, 0);" & ASCII.LF;
      S := S & "  Ch(68)" & ASCII.LF;
      S := S & "end CursorLeft;" & ASCII.LF;
      S := S & "procedure GetSize*(var w: integer; var h: integer);" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  w := 80;" & ASCII.LF;
      S := S & "  h := 25" & ASCII.LF;
      S := S & "end GetSize;" & ASCII.LF;
      S := S & "end Term." & ASCII.LF;
      return To_String (S);
   end Oak_Term_Src;

   function Oak_Reals_Src return String is
      S : Unbounded_String;
   begin
      S := S & "module Reals;" & ASCII.LF;
      S := S & "procedure Convert*(x: real; var str: array of char);" & ASCII.LF;
      S := S & "  var v: real; s: real; t: real; neg: boolean; e: integer; d: integer;" & ASCII.LF;
      S := S & "      k: integer; n: integer; i: integer;" & ASCII.LF;
      S := S & "" & ASCII.LF;
      S := S & "  procedure Put(ci: integer);" & ASCII.LF;
      S := S & "  begin" & ASCII.LF;
      S := S & "    if n < len(str) - 1 then" & ASCII.LF;
      S := S & "      str[n] := CHR(ci);" & ASCII.LF;
      S := S & "      n := n + 1" & ASCII.LF;
      S := S & "    end" & ASCII.LF;
      S := S & "  end Put;" & ASCII.LF;
      S := S & "" & ASCII.LF;
      S := S & "  procedure Digit;" & ASCII.LF;
      S := S & "  begin" & ASCII.LF;
      S := S & "    d := 0;" & ASCII.LF;
      S := S & "    t := 1.0;" & ASCII.LF;
      S := S & "    while v >= t do" & ASCII.LF;
      S := S & "      d := d + 1;" & ASCII.LF;
      S := S & "      t := t + 1.0" & ASCII.LF;
      S := S & "    end;" & ASCII.LF;
      S := S & "    Put(48 + d);" & ASCII.LF;
      S := S & "    s := 0.0;" & ASCII.LF;
      S := S & "    k := 0;" & ASCII.LF;
      S := S & "    while k < d do" & ASCII.LF;
      S := S & "      s := s + 1.0;" & ASCII.LF;
      S := S & "      k := k + 1" & ASCII.LF;
      S := S & "    end;" & ASCII.LF;
      S := S & "    v := (v - s) * 10.0" & ASCII.LF;
      S := S & "  end Digit;" & ASCII.LF;
      S := S & "" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  neg := false;" & ASCII.LF;
      S := S & "  v := x;" & ASCII.LF;
      S := S & "  if v < 0.0 then" & ASCII.LF;
      S := S & "    neg := true;" & ASCII.LF;
      S := S & "    v := 0.0 - v" & ASCII.LF;
      S := S & "  end;" & ASCII.LF;
      S := S & "  e := 0;" & ASCII.LF;
      S := S & "  if v >= 10.0 then" & ASCII.LF;
      S := S & "    while v >= 10.0 do" & ASCII.LF;
      S := S & "      v := v / 10.0;" & ASCII.LF;
      S := S & "      e := e + 1" & ASCII.LF;
      S := S & "    end" & ASCII.LF;
      S := S & "  elsif v > 0.0 then" & ASCII.LF;
      S := S & "    while v < 1.0 do" & ASCII.LF;
      S := S & "      v := v * 10.0;" & ASCII.LF;
      S := S & "      e := e - 1" & ASCII.LF;
      S := S & "    end" & ASCII.LF;
      S := S & "  end;" & ASCII.LF;
      S := S & "  n := 0;" & ASCII.LF;
      S := S & "  if neg then" & ASCII.LF;
      S := S & "    Put(45)" & ASCII.LF;
      S := S & "  end;" & ASCII.LF;
      S := S & "  Digit;" & ASCII.LF;
      S := S & "  Put(46);" & ASCII.LF;
      S := S & "  for i := 1 to 5 do" & ASCII.LF;
      S := S & "    Digit" & ASCII.LF;
      S := S & "  end;" & ASCII.LF;
      S := S & "  Put(69);" & ASCII.LF;
      S := S & "  if e < 0 then" & ASCII.LF;
      S := S & "    Put(45);" & ASCII.LF;
      S := S & "    e := 0 - e" & ASCII.LF;
      S := S & "  else" & ASCII.LF;
      S := S & "    Put(43)" & ASCII.LF;
      S := S & "  end;" & ASCII.LF;
      S := S & "  Put(48 + ((e div 10) mod 10));" & ASCII.LF;
      S := S & "  Put(48 + (e mod 10));" & ASCII.LF;
      S := S & "  for i := n to len(str) - 1 do" & ASCII.LF;
      S := S & "    str[i] := CHR(0)" & ASCII.LF;
      S := S & "  end" & ASCII.LF;
      S := S & "end Convert;" & ASCII.LF;
      S := S & "procedure ConvertTo*(var x: real; str: array of char);" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  x := RParse(str)" & ASCII.LF;
      S := S & "end ConvertTo;" & ASCII.LF;
      S := S & "procedure Ten*(e: integer): real;" & ASCII.LF;
      S := S & "  var i: integer; v: real;" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  v := 1.0;" & ASCII.LF;
      S := S & "  i := 0;" & ASCII.LF;
      S := S & "  if e > 0 then" & ASCII.LF;
      S := S & "    while i < e do" & ASCII.LF;
      S := S & "      v := v * 10.0;" & ASCII.LF;
      S := S & "      i := i + 1" & ASCII.LF;
      S := S & "    end" & ASCII.LF;
      S := S & "  else" & ASCII.LF;
      S := S & "    while i < 0 - e do" & ASCII.LF;
      S := S & "      v := v / 10.0;" & ASCII.LF;
      S := S & "      i := i + 1" & ASCII.LF;
      S := S & "    end" & ASCII.LF;
      S := S & "  end;" & ASCII.LF;
      S := S & "  return v" & ASCII.LF;
      S := S & "end Ten;" & ASCII.LF;
      S := S & "procedure Expo*(x: real): integer;" & ASCII.LF;
      S := S & "  var n: integer; v: real;" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  v := x;" & ASCII.LF;
      S := S & "  n := 0;" & ASCII.LF;
      S := S & "  if v < 0.0 then" & ASCII.LF;
      S := S & "    v := 0.0 - v" & ASCII.LF;
      S := S & "  end;" & ASCII.LF;
      S := S & "  if v # 0.0 then" & ASCII.LF;
      S := S & "    while v >= 10.0 do" & ASCII.LF;
      S := S & "      v := v / 10.0;" & ASCII.LF;
      S := S & "      n := n + 1" & ASCII.LF;
      S := S & "    end;" & ASCII.LF;
      S := S & "    while v < 1.0 do" & ASCII.LF;
      S := S & "      v := v * 10.0;" & ASCII.LF;
      S := S & "      n := n - 1" & ASCII.LF;
      S := S & "    end" & ASCII.LF;
      S := S & "  end;" & ASCII.LF;
      S := S & "  return n" & ASCII.LF;
      S := S & "end Expo;" & ASCII.LF;
      S := S & "end Reals." & ASCII.LF;
      return To_String (S);
   end Oak_Reals_Src;

   function Oak_MathL_Src return String is
      S : Unbounded_String;
   begin
      S := S & "module MathL;" & ASCII.LF;
      S := S & "const pi* = 3.141592653589793D0;" & ASCII.LF;
      S := S & "const e* = 2.718281828459045D0;" & ASCII.LF;
      S := S & "procedure power*(base: longreal; ex: longreal): longreal;" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  return Power(base, ex)" & ASCII.LF;
      S := S & "end power;" & ASCII.LF;
      S := S & "procedure exp*(x: longreal): longreal;" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  return Exp(x)" & ASCII.LF;
      S := S & "end exp;" & ASCII.LF;
      S := S & "procedure ln*(x: longreal): longreal;" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  return Ln(x)" & ASCII.LF;
      S := S & "end ln;" & ASCII.LF;
      S := S & "procedure log*(x: longreal; base: longreal): longreal;" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  return Log(x, base)" & ASCII.LF;
      S := S & "end log;" & ASCII.LF;
      S := S & "procedure sin*(x: longreal): longreal;" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  return Sin(x)" & ASCII.LF;
      S := S & "end sin;" & ASCII.LF;
      S := S & "procedure cos*(x: longreal): longreal;" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  return Cos(x)" & ASCII.LF;
      S := S & "end cos;" & ASCII.LF;
      S := S & "procedure tan*(x: longreal): longreal;" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  return Tan(x)" & ASCII.LF;
      S := S & "end tan;" & ASCII.LF;
      S := S & "procedure arcsin*(x: longreal): longreal;" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  return Arcsin(x)" & ASCII.LF;
      S := S & "end arcsin;" & ASCII.LF;
      S := S & "procedure arccos*(x: longreal): longreal;" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  return Arccos(x)" & ASCII.LF;
      S := S & "end arccos;" & ASCII.LF;
      S := S & "procedure arctan*(x: longreal): longreal;" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  return Arctan(x)" & ASCII.LF;
      S := S & "end arctan;" & ASCII.LF;
      S := S & "procedure arctan2*(y: longreal; x: longreal): longreal;" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  return Arctan2(y, x)" & ASCII.LF;
      S := S & "end arctan2;" & ASCII.LF;
      S := S & "end MathL." & ASCII.LF;
      return To_String (S);
   end Oak_MathL_Src;


   function Oak_Input_Src return String is
      S : Unbounded_String;
   begin
      S := S & "module Input;" & ASCII.LF;
      S := S & "var TimeUnit*: longint;" & ASCII.LF;
      S := S & "procedure Available*: integer;" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  return InAvail" & ASCII.LF;
      S := S & "end Available;" & ASCII.LF;
      S := S & "procedure Read*(var ch: char);" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  ch := InReadCh" & ASCII.LF;
      S := S & "end Read;" & ASCII.LF;
      S := S & "procedure Time*: longint;" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  return InTime" & ASCII.LF;
      S := S & "end Time;" & ASCII.LF;
      S := S & "procedure Mouse*(var keys: set; var x: integer; var y: integer);" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  keys := {};" & ASCII.LF;
      S := S & "  x := 0;" & ASCII.LF;
      S := S & "  y := 0" & ASCII.LF;
      S := S & "end Mouse;" & ASCII.LF;
      S := S & "procedure SetMouseLimits*(w: integer; h: integer);" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "end SetMouseLimits;" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  TimeUnit := 1000" & ASCII.LF;
      S := S & "end Input." & ASCII.LF;
      return To_String (S);
   end Oak_Input_Src;


   function Oak_XYplane_Src return String is
      S : Unbounded_String;
   begin
      S := S & "module XYplane;" & ASCII.LF;
      S := S & "const draw* = 1;" & ASCII.LF;
      S := S & "const erase* = 0;" & ASCII.LF;
      S := S & "var X*: integer;" & ASCII.LF;
      S := S & "var Y*: integer;" & ASCII.LF;
      S := S & "var W*: integer;" & ASCII.LF;
      S := S & "var H*: integer;" & ASCII.LF;
      S := S & "procedure Open*;" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  X := 0;" & ASCII.LF;
      S := S & "  Y := 0;" & ASCII.LF;
      S := S & "  W := 640;" & ASCII.LF;
      S := S & "  H := 400;" & ASCII.LF;
      S := S & "  PlaneOpen(W, H)" & ASCII.LF;
      S := S & "end Open;" & ASCII.LF;
      S := S & "procedure Clear*;" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  PlaneClear" & ASCII.LF;
      S := S & "end Clear;" & ASCII.LF;
      S := S & "procedure Dot*(x: integer; y: integer; mode: integer);" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  PlaneDot(x, y, mode)" & ASCII.LF;
      S := S & "end Dot;" & ASCII.LF;
      S := S & "procedure IsDot*(x: integer; y: integer): boolean;" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  return PlaneIsDot(x, y)" & ASCII.LF;
      S := S & "end IsDot;" & ASCII.LF;
      S := S & "procedure Key*: char;" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  return PlaneKey" & ASCII.LF;
      S := S & "end Key;" & ASCII.LF;
      S := S & "end XYplane." & ASCII.LF;
      return To_String (S);
   end Oak_XYplane_Src;


   function Oak_Args_Src return String is
      S : Unbounded_String;
   begin
      S := S & "module Args;" & ASCII.LF;
      S := S & "var count*: integer;" & ASCII.LF;
      S := S & "procedure Get*(n: integer; var arg: array of char; var res: integer);" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  ArgGet(n, arg, res)" & ASCII.LF;
      S := S & "end Get;" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  count := ArgCount" & ASCII.LF;
      S := S & "end Args." & ASCII.LF;
      return To_String (S);
   end Oak_Args_Src;

   function Oak_Err_Src return String is
      S : Unbounded_String;
   begin
      S := S & "module Err;" & ASCII.LF;
      S := S & "import Out;" & ASCII.LF;
      S := S & "procedure Write*(s: array of char);" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  Out.String(s)" & ASCII.LF;
      S := S & "end Write;" & ASCII.LF;
      S := S & "procedure WriteInt*(x: integer; w: integer);" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  Out.Int(x, w)" & ASCII.LF;
      S := S & "end WriteInt;" & ASCII.LF;
      S := S & "procedure WriteReal*(x: real; w: integer);" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  Out.Real(x, w)" & ASCII.LF;
      S := S & "end WriteReal;" & ASCII.LF;
      S := S & "procedure WriteLn*;" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  Out.Ln" & ASCII.LF;
      S := S & "end WriteLn;" & ASCII.LF;
      S := S & "end Err." & ASCII.LF;
      return To_String (S);
   end Oak_Err_Src;


   function Oak_Env_Src return String is
      S : Unbounded_String;
   begin
      S := S & "module Env;" & ASCII.LF;
      S := S & "procedure Get*(name: array of char; var value: array of char);" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  EnvGet(name, value)" & ASCII.LF;
      S := S & "end Get;" & ASCII.LF;
      S := S & "procedure Set*(name: array of char; value: array of char);" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  EnvSet(name, value)" & ASCII.LF;
      S := S & "end Set;" & ASCII.LF;
      S := S & "end Env." & ASCII.LF;
      return To_String (S);
   end Oak_Env_Src;


   function Oak_Convert_Src return String is
      S : Unbounded_String;
   begin
      S := S & "module Convert;" & ASCII.LF;
      S := S & "import Reals;" & ASCII.LF;
      S := S & "procedure ToInt*(str: array of char; var x: integer; var res: integer);" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  ConvToInt(str, x, res)" & ASCII.LF;
      S := S & "end ToInt;" & ASCII.LF;
      S := S & "procedure ToReal*(str: array of char; var x: real; var res: integer);" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  ConvToReal(str, x, res)" & ASCII.LF;
      S := S & "end ToReal;" & ASCII.LF;
      S := S & "procedure FromInt*(x: integer; var str: array of char);" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  ConvFromInt(x, str)" & ASCII.LF;
      S := S & "end FromInt;" & ASCII.LF;
      S := S & "procedure FromReal*(x: real; var str: array of char);" & ASCII.LF;
      S := S & "begin" & ASCII.LF;
      S := S & "  Reals.Convert(x, str)" & ASCII.LF;
      S := S & "end FromReal;" & ASCII.LF;
      S := S & "end Convert." & ASCII.LF;
      return To_String (S);
   end Oak_Convert_Src;


   function Compile_Multi (Main_Source : String; Libs : Lib_Array;
                           N_Libs : Natural; Count : out Natural)
                           return Unit_Array
   is
      Res : Unit_Array;
      C   : Natural := 0;
      M_T, S_T, B_T : Unbounded_String;
      Skip_Math : Boolean := False;

      procedure Add (File : String; T : Unbounded_String) is
      begin
         C := C + 1;
         if C > Res'Last then
            raise O2c_Error with "too many generated units";
         end if;
         Res (C) := (File => To_Unbounded_String (File), Text => T);
      end Add;
      --  Which modules this call's sources import.
      --
      --  The builtin Oakwood modules are embedded SOURCE, so they must be
      --  parsed on every call - imports have to resolve and user code is
      --  checked against their types - but there is no reason to EMIT them
      --  all: a program importing only Out used to drag thirteen builtin Ada
      --  units into its output, and into whatever compiles that output.
      --  Gather the import clauses first, then emit only what is reached.
      --
      --  Sizing: an import clause names a screenful at most.  The bound is a
      --  guard against a pathological source and raises rather than quietly
      --  emitting less than the program needs.
      Max_Imports_Seen : constant := 64;
      Seen   : array (1 .. Max_Imports_Seen) of Unbounded_String;
      N_Seen : Natural := 0;

      procedure Note_Import (Name : String) is
      begin
         for I in 1 .. N_Seen loop
            if Eq_No_Case (To_String (Seen (I)), Name) then
               return;
            end if;
         end loop;
         if N_Seen = Max_Imports_Seen then
            raise O2c_Error with "more than"
              & Natural'Image (Max_Imports_Seen) & " imported names";
         end if;
         N_Seen := N_Seen + 1;
         Seen (N_Seen) := To_Unbounded_String (Name);
      end Note_Import;

      procedure Gather_Imports (Src : String) is
         use type O2c_Lexer.Token_Kind;
         T : O2c_Lexer.Token;
      begin
         --  Through the LEXER, not a text search: "import" inside a comment
         --  or a string literal must not count.
         O2c_Lexer.Init (Src);
         loop
            T := O2c_Lexer.Next_Token;
            exit when T.Kind = O2c_Lexer.Tok_EOF;
            if T.Kind = O2c_Lexer.Tok_Import then
               loop
                  T := O2c_Lexer.Next_Token;
                  exit when T.Kind /= O2c_Lexer.Tok_Ident;
                  Note_Import (T.Text (1 .. T.Len));
                  T := O2c_Lexer.Next_Token;   --  ',' or ';'
                  exit when T.Kind /= O2c_Lexer.Tok_Comma;
               end loop;
            end if;
         end loop;
      end Gather_Imports;

      function Imported (Name : String) return Boolean is
      begin
         for I in 1 .. N_Seen loop
            if Eq_No_Case (To_String (Seen (I)), Name) then
               return True;
            end if;
         end loop;
         return False;
      end Imported;

      --  Emit a builtin's units?  None in bytecode mode: the VM calls the
      --  Oakwood surface as NATIVES, so the Ada units are irrelevant there
      --  (and the image carries imports in its own tables).  Otherwise emit
      --  only what something imports.
      --
      --  One builtin imports another - Convert imports Reals (M52) - so
      --  Reals is emitted whenever Convert is.  If more such edges appear
      --  this wants a closure rather than a special case.
      function Emits (Name : String) return Boolean is
        (not Bytecode_Requested
         and then (Imported (Name)
                   or else (Name = "Reals" and then Imported ("Convert"))));

   begin
      N_X := 0;
      N_Prov := 0;
      Multi_Ok := True;

      --  Collect imports first (see Emits).
      Gather_Imports (Main_Source);
      for I in 1 .. N_Libs loop
         Gather_Imports (To_String (Libs (I).Text));
      end loop;

      for I in 1 .. N_Libs loop
         if To_String (Libs (I).Name) = "Math" then
            Skip_Math := True;
         end if;
      end loop;
      --  M21: shared support types (O2c_Int_Arr / O2c_Bool_Arr /
      --  O2c_Set) live in one package every unit withs and uses, so
      --  cross-module SET values and open-array formals share types.
      Add ("o2c_types.ads",
           To_Unbounded_String
             ("with Interfaces;" & ASCII.LF
              & "package O2c_Types is" & ASCII.LF
              & "   type O2c_Int_Arr is array (Integer range <>)"
              & " of Integer;" & ASCII.LF
              & "   type O2c_Bool_Arr is array (Integer range <>)"
              & " of Boolean;" & ASCII.LF
              & "   type O2c_Set is mod 2**32;" & ASCII.LF
              & "end O2c_Types;" & ASCII.LF));
      --  M38: compile the builtin Oakwood modules first so that user
      --  modules and the main can import them
      Compile_Module (Oak_Strings_Src, True, M_T, S_T, B_T);
      if Emits ("Strings") then
         --  Strings: parsed above in every case, emitted
         --  only when something imports it (see Emits).
      Add (Lower (Ada_Id (To_String (Mod_Name))) & ".ads", S_T);
      if Length (B_T) > 0 then
         Add (Lower (Ada_Id (To_String (Mod_Name))) & ".adb", B_T);
      end if;
      end if;
      N_Prov := N_Prov + 1;
      Provided (N_Prov) := Mod_Name;

      Compile_Module (Oak_Texts_Src, True, M_T, S_T, B_T);
      if Emits ("Texts") then
         --  Texts: parsed above in every case, emitted
         --  only when something imports it (see Emits).
      Add (Lower (Ada_Id (To_String (Mod_Name))) & ".ads", S_T);
      if Length (B_T) > 0 then
         Add (Lower (Ada_Id (To_String (Mod_Name))) & ".adb", B_T);
      end if;
      end if;
      N_Prov := N_Prov + 1;
      Provided (N_Prov) := Mod_Name;

      Compile_Module (Oak_Files_Src, True, M_T, S_T, B_T);
      if Emits ("Files") then
         --  Files: parsed above in every case, emitted
         --  only when something imports it (see Emits).
      Add (Lower (Ada_Id (To_String (Mod_Name))) & ".ads", S_T);
      if Length (B_T) > 0 then
         Add (Lower (Ada_Id (To_String (Mod_Name))) & ".adb", B_T);
      end if;
      end if;
      N_Prov := N_Prov + 1;
      Provided (N_Prov) := Mod_Name;

      --  M41: the Oakwood Math builtin.  A user library named Math
      --  wins over the builtin (the dogfood demo used to own the
      --  name); otherwise Math is auto-provided like the others.
      if not Skip_Math then
         Compile_Module (Oak_Math_Src, True, M_T, S_T, B_T);
         if Emits ("Math") then
            --  Math: parsed above in every case, emitted only when
            --  something imports it (see Emits).
            Add (Lower (Ada_Id (To_String (Mod_Name))) & ".ads", S_T);
            if Length (B_T) > 0 then
               Add (Lower (Ada_Id (To_String (Mod_Name))) & ".adb", B_T);
            end if;
         end if;
         N_Prov := N_Prov + 1;
         Provided (N_Prov) := Mod_Name;
      end if;

      Compile_Module (Oak_MathL_Src, True, M_T, S_T, B_T);
      if Emits ("MathL") then
         --  MathL: parsed above in every case, emitted
         --  only when something imports it (see Emits).
      Add (Lower (Ada_Id (To_String (Mod_Name))) & ".ads", S_T);
      if Length (B_T) > 0 then
         Add (Lower (Ada_Id (To_String (Mod_Name))) & ".adb", B_T);
      end if;
      end if;
      N_Prov := N_Prov + 1;
      Provided (N_Prov) := Mod_Name;

      Compile_Module (Oak_Input_Src, True, M_T, S_T, B_T);
      if Emits ("Input") then
         --  Input: parsed above in every case, emitted
         --  only when something imports it (see Emits).
      Add (Lower (Ada_Id (To_String (Mod_Name))) & ".ads", S_T);
      if Length (B_T) > 0 then
         Add (Lower (Ada_Id (To_String (Mod_Name))) & ".adb", B_T);
      end if;
      end if;
      N_Prov := N_Prov + 1;
      Provided (N_Prov) := Mod_Name;

      Compile_Module (Oak_XYplane_Src, True, M_T, S_T, B_T);
      if Emits ("XYplane") then
         --  XYplane: parsed above in every case, emitted
         --  only when something imports it (see Emits).
      Add (Lower (Ada_Id (To_String (Mod_Name))) & ".ads", S_T);
      if Length (B_T) > 0 then
         Add (Lower (Ada_Id (To_String (Mod_Name))) & ".adb", B_T);
      end if;
      end if;
      N_Prov := N_Prov + 1;
      Provided (N_Prov) := Mod_Name;

      Compile_Module (Oak_Args_Src, True, M_T, S_T, B_T);
      if Emits ("Args") then
         --  Args: parsed above in every case, emitted
         --  only when something imports it (see Emits).
      Add (Lower (Ada_Id (To_String (Mod_Name))) & ".ads", S_T);
      if Length (B_T) > 0 then
         Add (Lower (Ada_Id (To_String (Mod_Name))) & ".adb", B_T);
      end if;
      end if;
      N_Prov := N_Prov + 1;
      Provided (N_Prov) := Mod_Name;

      Compile_Module (Oak_Err_Src, True, M_T, S_T, B_T);
      if Emits ("Err") then
         --  Err: parsed above in every case, emitted
         --  only when something imports it (see Emits).
      Add (Lower (Ada_Id (To_String (Mod_Name))) & ".ads", S_T);
      if Length (B_T) > 0 then
         Add (Lower (Ada_Id (To_String (Mod_Name))) & ".adb", B_T);
      end if;
      end if;
      N_Prov := N_Prov + 1;
      Provided (N_Prov) := Mod_Name;

      Compile_Module (Oak_Env_Src, True, M_T, S_T, B_T);
      if Emits ("Env") then
         --  Env: parsed above in every case, emitted
         --  only when something imports it (see Emits).
      Add (Lower (Ada_Id (To_String (Mod_Name))) & ".ads", S_T);
      if Length (B_T) > 0 then
         Add (Lower (Ada_Id (To_String (Mod_Name))) & ".adb", B_T);
      end if;
      end if;
      N_Prov := N_Prov + 1;
      Provided (N_Prov) := Mod_Name;

      Compile_Module (Oak_In_Src, True, M_T, S_T, B_T);
      if Emits ("In") then
         --  In: parsed above in every case, emitted
         --  only when something imports it (see Emits).
      Add (Lower (Ada_Id (To_String (Mod_Name))) & ".ads", S_T);
      if Length (B_T) > 0 then
         Add (Lower (Ada_Id (To_String (Mod_Name))) & ".adb", B_T);
      end if;
      end if;
      N_Prov := N_Prov + 1;
      Provided (N_Prov) := Mod_Name;

      Compile_Module (Oak_Reals_Src, True, M_T, S_T, B_T);
      if Emits ("Reals") then
         --  Reals: parsed above in every case, emitted
         --  only when something imports it (see Emits).
      Add (Lower (Ada_Id (To_String (Mod_Name))) & ".ads", S_T);
      if Length (B_T) > 0 then
         Add (Lower (Ada_Id (To_String (Mod_Name))) & ".adb", B_T);
      end if;
      end if;
      N_Prov := N_Prov + 1;
      Provided (N_Prov) := Mod_Name;

      Compile_Module (Oak_Term_Src, True, M_T, S_T, B_T);
      if Emits ("Term") then
         --  Term: parsed above in every case, emitted
         --  only when something imports it (see Emits).
      Add (Lower (Ada_Id (To_String (Mod_Name))) & ".ads", S_T);
      if Length (B_T) > 0 then
         Add (Lower (Ada_Id (To_String (Mod_Name))) & ".adb", B_T);
      end if;
      end if;
      N_Prov := N_Prov + 1;
      Provided (N_Prov) := Mod_Name;

      Compile_Module (Oak_Convert_Src, True, M_T, S_T, B_T);
      if Emits ("Convert") then
         --  Convert: parsed above in every case, emitted
         --  only when something imports it (see Emits).
      Add (Lower (Ada_Id (To_String (Mod_Name))) & ".ads", S_T);
      if Length (B_T) > 0 then
         Add (Lower (Ada_Id (To_String (Mod_Name))) & ".adb", B_T);
      end if;
      end if;
      N_Prov := N_Prov + 1;
      Provided (N_Prov) := Mod_Name;

      for I in 1 .. N_Libs loop
         if not Is_Provided (To_String (Libs (I).Name)) then
            --  skip a user module that duplicates a builtin (M38)
            Compile_Module (To_String (Libs (I).Text), True,
                            M_T, S_T, B_T);
            Add (Lower (Ada_Id (To_String (Mod_Name))) & ".ads", S_T);
            if Length (B_T) > 0 then
               Add (Lower (Ada_Id (To_String (Mod_Name))) & ".adb", B_T);
            end if;
            N_Prov := N_Prov + 1;
            Provided (N_Prov) := Mod_Name;
         end if;
      end loop;
      if Bytecode_Requested then
         O2c_BC.Begin_Mode;
      end if;
      Compile_Module (Main_Source, False, M_T, S_T, B_T);
      if O2c_BC.Bytecode_Mode then
         --  the program ends where the module body ends; Encode resolves
         --  the control-flow fixups the hooks recorded
         O2c_BC.Halt_Program;
         Bc_Image := To_Unbounded_String (O2c_BC.Encode);
         O2c_BC.Finish;
      end if;
      Add (Lower (Ada_Id (To_String (Mod_Name))) & ".adb", M_T);
      Count := C;
      return Res;
   end Compile_Multi;

end O2c_Compiler;
