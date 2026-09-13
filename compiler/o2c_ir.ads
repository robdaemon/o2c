--  The IR: three-address quads over typed values.
--
--  M53 records this project's architecture as STACK bytecode with a
--  three-address IR underneath.  This package is that layer's seam.  Today the
--  front end emits inline as it parses: the Ada text and the bytecode are
--  produced in the same branches, roughly 500 emitter calls sit inside a
--  12k-line parser, and a construct with no bytecode case is indistinguishable
--  from one that needs none - which is how seven silent-wrong-answer bugs were
--  found rather than refused (see docs/RESUME.md 3aj-3ah).
--
--  The IR fixes that structurally, in two ways:
--
--    * the front end BUILDS quads; a backend LOWERS them.  The calling
--      convention, the base-derivation arithmetic and the stack discipline live
--      in the lowering pass, in one place, instead of being duplicated per
--      branch - which is what made one base-derivation fix take three attempts
--      (3ak-3am);
--    * every consumer `case`s over `Op`, so an op with no lowering is a
--      COMPILE ERROR in the consumer rather than a silently empty image.  Ada
--      makes that exhaustive, which is the point of choosing a closed set of
--      quads.
--
--  M1 is the seam only: types, builders and the iteration interface.  Nothing
--  in the parser changes, so no fixture can move.
with Ada.Strings.Unbounded;
use Ada.Strings.Unbounded;

package O2c_Ir is

   --  ---- identifiers -----------------------------------------------------

   type Value_Id is new Natural;
   type Quad_Id  is new Natural;
   type Label_Id is new Natural;

   No_Value : constant Value_Id := 0;
   No_Quad  : constant Quad_Id  := 0;

   --  ---- values ----------------------------------------------------------

   --  How a value is stored.  Deliberately abstract: the IR does not know the
   --  front end's EType or UTypes tables.  It carries a kind, a type id the
   --  front end issued, and a size, and the lowering resolves the rest.
   type Value_Kind is (V_Temp,        --  a temporary the IR allocated
                       V_Local,       --  a frame slot
                       V_Global,      --  a module-global slot
                       V_Const_Int,
                       V_Const_Real,
                       V_Const_Str,   --  interned text
                       V_Label);

   type Value_Info is record
      Kind  : Value_Kind := V_Temp;
      Typ   : Natural := 0;   --  opaque type id, issued by the front end
      Slots : Natural := 1;   --  storage, in eight-byte slots
      Bytes : Natural := 0;   --  packed byte length, 0 when not packed
      Int   : Long_Integer := 0;
      Real  : Long_Float := 0.0;
      Name  : Unbounded_String;   --  local/global name, or interned text
   end record;

   --  ---- quads -----------------------------------------------------------

   --  A closed set: every consumer must handle every member, which is what
   --  turns "this construct has no case" from a silent image into a build
   --  error.  The set grows a stage at a time, deliberately.
   type Op is (Op_Nop,

               --  arithmetic and comparison, three-address
               Op_Copy,                      --  d := s1
               Op_Add, Op_Sub, Op_Mul, Op_Div, Op_Mod, Op_Neg,
               Op_Eq, Op_Ne, Op_Lt, Op_Le, Op_Gt, Op_Ge,
               Op_Not, Op_And, Op_Or,

               --  memory: addresses are values, so this is one level
               Op_Load,                      --  d := *s1
               Op_Store,                     --  *d := s1
               Op_Addr_Local,                --  d := &s1
               Op_Addr_Global,               --  d := &s1

               --  control flow within a procedure
               Op_Label,                     --  d's label is defined here
               Op_Jump,                      --  to s1
               Op_Jump_False,                --  to s1 when s2 is false

               --  calls.  Op_Arg quads immediately before an Op_Call are its
               --  arguments, in order - which keeps every quad three-address.
               Op_Arg,
               Op_Call,                      --  d := call s1
               Op_Return,                    --  return s1
               Op_Halt);

   type Quad_Info is record
      Op  : O2c_Ir.Op := Op_Nop;
      Dst : Value_Id := No_Value;
      Src1 : Value_Id := No_Value;
      Src2 : Value_Id := No_Value;
   end record;

   --  ---- building --------------------------------------------------------

   --  Capacity is a compiler-input argument, not a hardware limit: exceeding it
   --  is reported, never truncated (the project's rule for fixed tables).
   procedure Init (Max_Values : Natural := 4096;
                   Max_Quads  : Natural := 16384;
                   Max_Labels : Natural := 1024);

   --  Start a fresh procedure's quad stream.  Values and labels are per
   --  procedure, so this is where a procedure begins.
   procedure Begin_Proc;

   function New_Temp (Typ : Natural; Slots : Natural := 1) return Value_Id;
   function New_Local (Name : String; Typ : Natural;
                       Slots : Natural := 1) return Value_Id;
   function New_Global (Name : String; Typ : Natural;
                        Slots : Natural := 1) return Value_Id;

   function Const_Int (V : Long_Integer; Typ : Natural := 0)
                      return Value_Id;
   function Const_Real (V : Long_Float; Typ : Natural := 0) return Value_Id;
   function Const_Str (Text : String) return Value_Id;

   function New_Label return Label_Id;
   function Label_Value (L : Label_Id) return Value_Id;

   --  Emit a quad.  The parameterless forms exist so a call site reads like
   --  the instruction it is: Emit (Op_Add, D, A, B).
   procedure Emit (Op : O2c_Ir.Op;
                   Dst : Value_Id := No_Value;
                   Src1 : Value_Id := No_Value;
                   Src2 : Value_Id := No_Value);

   --  ---- reading it back: the walker interface ---------------------------

   function Quad_Count return Natural;
   function Quad_At (Q : Quad_Id) return Quad_Info;
   function Value_At (V : Value_Id) return Value_Info;

   --  ---- diagnostics -----------------------------------------------------

   procedure Dump;

end O2c_Ir;
