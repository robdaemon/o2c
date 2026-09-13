with Ada.Text_IO;

package body O2c_Ir is

   --  The tables are HEAP-allocated and sized by Init, not declared here as
   --  large arrays: the compiler itself runs in the Aegir guest, whose user
   --  stack is 256 KiB and whose static-data budget is not something this
   --  package should assume.  Overflow is reported, never truncated (the
   --  project's rule for capacity tables) - and the initial capacity is modest
   --  because M1 has no consumer yet: it is sized for M2's single construct and
   --  must be revisited, with a written justification, when a real consumer
   --  arrives.
   type Value_Array is array (Natural range <>) of Value_Info;
   type Quad_Array  is array (Natural range <>) of Quad_Info;
   type Bool_Array  is array (Natural range <>) of Boolean;

   type Value_Array_Access is access Value_Array;
   type Quad_Array_Access  is access Quad_Array;
   type Bool_Array_Access  is access Bool_Array;

   Values : Value_Array_Access := null;
   Quads  : Quad_Array_Access  := null;
   Defined : Bool_Array_Access := null;

   N_Values  : Natural := 0;
   N_Quads   : Natural := 0;
   N_Labels  : Natural := 0;
   Cap_Values : Natural := 0;
   Cap_Quads  : Natural := 0;
   Cap_Labels : Natural := 0;

   --  A body completing a declaration must repeat the defaults TEXTUALLY -
   --  the same expression as the spec's, which is why these are literals and
   --  not the named constants they used to be.  4_096 values, 16_384 quads and
   --  1_024 labels; modest because M1 has no consumer yet.
   procedure Init (Max_Values : Natural := 4_096;
                   Max_Quads  : Natural := 16_384;
                   Max_Labels : Natural := 1_024) is
   begin
      if Max_Values = 0 or else Max_Quads = 0 or else Max_Labels = 0 then
         raise Program_Error with "O2c_Ir.Init: a zero capacity";
      end if;
      Values  := new Value_Array (1 .. Max_Values);
      Quads   := new Quad_Array (1 .. Max_Quads);
      Defined := new Bool_Array (1 .. Max_Labels);
      Cap_Values := Max_Values;
      Cap_Quads  := Max_Quads;
      Cap_Labels := Max_Labels;
      N_Values := 0;
      N_Quads  := 0;
      N_Labels := 0;
   end Init;

   procedure Require_Init is
   begin
      if Values = null then
         raise Program_Error with "O2c_Ir: Init was not called";
      end if;
   end Require_Init;

   procedure Begin_Proc is
   begin
      --  Values and labels are per procedure; quads accumulate for the whole
      --  module so a consumer can walk each procedure's run in order.
      N_Values := 0;
      N_Labels := 0;
   end Begin_Proc;

   function Add_Value (V : Value_Info) return Value_Id is
   begin
      Require_Init;
      if N_Values = Cap_Values then
         raise Program_Error with "O2c_Ir: too many values";
      end if;
      N_Values := N_Values + 1;
      Values (N_Values) := V;
      return Value_Id (N_Values);
   end Add_Value;

   function New_Temp (Typ : Natural; Slots : Natural := 1) return Value_Id is
   begin
      return Add_Value ((Kind => V_Temp, Typ => Typ, Slots => Slots,
                         others => <>));
   end New_Temp;

   function New_Local (Name : String; Typ : Natural;
                       Slots : Natural := 1) return Value_Id is
   begin
      return Add_Value ((Kind => V_Local, Typ => Typ, Slots => Slots,
                         Name => To_Unbounded_String (Name),
                         others => <>));
   end New_Local;

   function New_Global (Name : String; Typ : Natural;
                        Slots : Natural := 1) return Value_Id is
   begin
      return Add_Value ((Kind => V_Global, Typ => Typ, Slots => Slots,
                         Name => To_Unbounded_String (Name),
                         others => <>));
   end New_Global;

   function Const_Int (V : Long_Integer; Typ : Natural := 0)
                      return Value_Id is
   begin
      return Add_Value ((Kind => V_Const_Int, Typ => Typ, Int => V,
                         others => <>));
   end Const_Int;

   function Const_Real (V : Long_Float; Typ : Natural := 0) return Value_Id is
   begin
      return Add_Value ((Kind => V_Const_Real, Typ => Typ, Real => V,
                         others => <>));
   end Const_Real;

   function Const_Str (Text : String) return Value_Id is
   begin
      return Add_Value ((Kind => V_Const_Str,
                         Name => To_Unbounded_String (Text),
                         others => <>));
   end Const_Str;

   function New_Label return Label_Id is
   begin
      Require_Init;
      if N_Labels = Cap_Labels then
         raise Program_Error with "O2c_Ir: too many labels";
      end if;
      N_Labels := N_Labels + 1;
      return Label_Id (N_Labels);
   end New_Label;

   function Label_Value (L : Label_Id) return Value_Id is
   begin
      Require_Init;
      if Natural (L) = 0 or else Natural (L) > N_Labels then
         raise Program_Error with "O2c_Ir: no such label";
      end if;
      return Add_Value ((Kind => V_Label, Int => Long_Integer (L),
                         others => <>));
   end Label_Value;

   procedure Emit (Op : O2c_Ir.Op;
                   Dst : Value_Id := No_Value;
                   Src1 : Value_Id := No_Value;
                   Src2 : Value_Id := No_Value) is
   begin
      Require_Init;
      if N_Quads = Cap_Quads then
         raise Program_Error with "O2c_Ir: too many quads";
      end if;
      N_Quads := N_Quads + 1;
      Quads (N_Quads) := (Op => Op, Dst => Dst, Src1 => Src1, Src2 => Src2);
   end Emit;

   function Quad_Count return Natural is
   begin
      return N_Quads;
   end Quad_Count;

   function Quad_At (Q : Quad_Id) return Quad_Info is
   begin
      if Natural (Q) = 0 or else Natural (Q) > N_Quads then
         raise Program_Error with "O2c_Ir: no such quad";
      end if;
      return Quads (Natural (Q));
   end Quad_At;

   function Value_At (V : Value_Id) return Value_Info is
   begin
      if Natural (V) = 0 or else Natural (V) > N_Values then
         raise Program_Error with "O2c_Ir: no such value";
      end if;
      return Values (Natural (V));
   end Value_At;

   procedure Dump is
   begin
      for Q in 1 .. N_Quads loop
         Ada.Text_IO.Put_Line
           (Ada.Text_IO.Standard_Error,
            "IR" & Natural'Image (Q) & "  " & Op'Image (Quads (Q).Op)
            & " d=" & Natural'Image (Natural (Quads (Q).Dst))
            & " s1=" & Natural'Image (Natural (Quads (Q).Src1))
            & " s2=" & Natural'Image (Natural (Quads (Q).Src2)));
      end loop;
   end Dump;

end O2c_Ir;
