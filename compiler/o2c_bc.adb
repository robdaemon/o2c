--  Bytecode emission state for the o2c bytecode backend (M53).
--
--  Sizing note (project rule on fixed tables): the label and fixup tables
--  are sized for the *slice* - a module body with the control flow a test
--  program needs - and raise rather than silently overflow.  They become
--  growable (or per-procedure) when procedures land.
with Ada.Strings.Unbounded;  use Ada.Strings.Unbounded;
with Interfaces;

package body O2c_BC is

   subtype Byte is Interfaces.Unsigned_8;
   subtype U16  is Interfaces.Unsigned_16;
   subtype U32  is Interfaces.Unsigned_32;
   subtype U64  is Interfaces.Unsigned_64;

   use type Interfaces.Unsigned_16;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;

   Max_Globals : constant := 256;
   Max_Labels  : constant := 512;
   Max_Fixups  : constant := 2048;

   --  ---- state -----------------------------------------------------------
   Code     : Unbounded_String;         --  code-relative bytes
   Words    : Unbounded_String;         --  CONST pool words (8 bytes each)
   N_Words  : Natural := 0;
   N_Insns  : Natural := 0;

   type Global_Rec is record
      Name : Unbounded_String;
   end record;
   Globals   : array (1 .. Max_Globals) of Global_Rec;
   N_Globals : Natural := 0;

   --  Pool words that hold a string's offset: patched at Encode time, once
   --  every string's position in the CONST payload is known.
   type Str_Word is record
      Word : Natural;      --  0-based pool word index
      Slot : Natural;      --  0-based string index
   end record;
   Str_Words : array (1 .. Max_Labels) of Str_Word;
   N_Str_Words : Natural := 0;

   --  Strings, kept separately so their layout can be computed at Encode
   type Str_Rec is record
      Text : Unbounded_String;      --  bytes, NUL included
   end record;
   Str_List : array (1 .. Max_Labels) of Str_Rec;
   N_Strings : Natural := 0;

   Labels : array (1 .. Max_Labels) of Integer := (others => -1);
   N_Labels_Used : Natural := 0;

   type Fixup is record
      Pos   : Natural;      --  code offset of the u32 operand
      Label : Natural;
   end record;
   Fixups    : array (1 .. Max_Fixups) of Fixup;
   N_Fixups  : Natural := 0;

   Depth     : Integer := 0;
   Max_Depth : Integer := 0;

   --  ---- small encoders --------------------------------------------------
   procedure Put_Byte (V : U64) is
   begin
      Code := Code & Character'Val (V mod 256);
   end Put_Byte;

   procedure Put_U16 (V : U16) is
   begin
      Code := Code & Character'Val (V mod 256);
      Code := Code & Character'Val ((V / 256) mod 256);
   end Put_U16;

   procedure Put_U32 (V : U32) is
   begin
      for K in 0 .. 3 loop
         Code := Code & Character'Val ((V / 256 ** K) mod 256);
      end loop;
   end Put_U32;

   function Len_Of (S : Unbounded_String) return Natural is
     (Length (S));

   --  ---- stack model -----------------------------------------------------
   procedure Pushed (N : Natural := 1) is
   begin
      Depth := Depth + Integer (N);
      if Depth > Max_Depth then
         Max_Depth := Depth;
      end if;
   end Pushed;

   procedure Popped (N : Natural := 1) is
   begin
      Depth := Depth - Integer (N);
      if Depth < 0 then
         --  the front end emitted an unbalanced expression: this is a
         --  backend bug, not a program bug, so say so loudly
         raise Wrong_Construct with "bytecode emitter: operand-stack "
           & "underflow";
      end if;
   end Popped;

   --  ---- mode ------------------------------------------------------------
   procedure Reset is
   begin
      Code := Null_Unbounded_String;
      Words := Null_Unbounded_String;
      N_Words := 0;
      N_Insns := 0;
      N_Globals := 0;
      N_Str_Words := 0;
      N_Strings := 0;
      N_Fixups := 0;
      N_Labels_Used := 0;
      Depth := 0;
      Max_Depth := 0;
      for I in Labels'Range loop
         Labels (I) := -1;
      end loop;
   end Reset;

   procedure Begin_Mode is
   begin
      Reset;
      Bytecode_Mode := True;
   end Begin_Mode;

   procedure Finish is
   begin
      Bytecode_Mode := False;
   end Finish;

   --  ---- globals ---------------------------------------------------------
   function Global (Ada_Name : String) return Natural is
   begin
      if not Bytecode_Mode then
         --  interned outside a program: Begin_Mode's reset would wipe it,
         --  so this is a backend bug worth failing loudly on
         raise Wrong_Construct with "bytecode backend: Global before "
           & "Begin_Mode";
      end if;
      for I in 1 .. N_Globals loop
         if To_String (Globals (I).Name) = Ada_Name then
            return I - 1;
         end if;
      end loop;
      if N_Globals = Max_Globals then
         raise Wrong_Construct with "bytecode backend: too many globals";
      end if;
      N_Globals := N_Globals + 1;
      Globals (N_Globals).Name := To_Unbounded_String (Ada_Name);
      return N_Globals - 1;
   end Global;

   function Global_Count return Natural is
     (N_Globals);

   --  ---- constants -------------------------------------------------------
   --  A pool word holding an INTEGER: two's complement in 64 bits, so the
   --  VM's signed interpretation of the slot is exact (a plain conversion
   --  of a negative value would zero-extend and read back positive).
   function Word_Of (V : Integer) return U64 is
     (if V >= 0 then U64 (V) else U64'Last - U64 (-(V + 1)));

   procedure Add_Word (V : U64) is
   begin
      for K in 0 .. 7 loop
         Words := Words & Character'Val ((V / 2 ** (8 * K)) mod 256);
      end loop;
      N_Words := N_Words + 1;
   end Add_Word;

   procedure Push_Int (Value : Integer) is
   begin
      Add_Word (Word_Of (Value));
      Put_Byte (16#14#);          --  LOAD_CONST
      Put_U32 (U32 (N_Words - 1));
      N_Insns := N_Insns + 1;
      Pushed;
   end Push_Int;

   procedure Push_Char (Value : Integer) is
   begin
      Push_Int (Value);
   end Push_Char;

   procedure Push_Bool (Value : Boolean) is
   begin
      if Value then
         Push_Int (1);
      else
         Push_Int (0);
      end if;
   end Push_Bool;

   procedure Push_Str (Text : String) is
   begin
      if N_Strings = Max_Labels then
         raise Wrong_Construct with "bytecode backend: too many strings";
      end if;
      N_Strings := N_Strings + 1;
      Str_List (N_Strings).Text := To_Unbounded_String (Text & Character'Val (0));
      Add_Word (0);                              --  patched at Encode
      if N_Str_Words = Max_Labels then
         raise Wrong_Construct with "bytecode backend: too many strings";
      end if;
      N_Str_Words := N_Str_Words + 1;
      Str_Words (N_Str_Words) := (Word => N_Words - 1, Slot => N_Strings - 1);
      Put_Byte (16#14#);                        --  LOAD_CONST
      Put_U32 (U32 (N_Words - 1));
      N_Insns := N_Insns + 1;
      Pushed;
   end Push_Str;

   --  ---- loads and stores ------------------------------------------------
   procedure Load (Idx : Natural) is
   begin
      Put_Byte (16#12#);          --  LOAD_G
      Put_U32 (U32 (Idx));
      N_Insns := N_Insns + 1;
      Pushed;
   end Load;

   procedure Store (Idx : Natural) is
   begin
      Put_Byte (16#13#);          --  STORE_G
      Put_U32 (U32 (Idx));
      N_Insns := N_Insns + 1;
      Popped;
   end Store;

   --  ---- operators -------------------------------------------------------
   function Byte_Of (O : Op) return Byte is
     (case O is
        when Nop         => 16#00#,
        when Halt        => 16#01#,
        when Dup         => 16#02#,
        when Drop        => 16#03#,
        when Assert_Fail => 16#05#,
        when Trap        => 16#06#,
        when Load_G      => 16#12#,
        when Store_G     => 16#13#,
        when Load_Const  => 16#14#,
        when Add         => 16#30#,
        when Sub         => 16#31#,
        when Mul         => 16#32#,
        when IDiv        => 16#33#,
        when IMod        => 16#34#,
        when Neg         => 16#35#,
        when IAbs        => 16#36#,
        when Eq          => 16#37#,
        when Ne          => 16#38#,
        when Lt          => 16#39#,
        when Le          => 16#3A#,
        when Gt          => 16#3B#,
        when Ge          => 16#3C#,
        when Btest       => 16#68#,
        when Ord         => 16#70#,
        when Chr         => 16#71#,
        when Jmp         => 16#A0#,
        when Jz          => 16#A1#,
        when Jnz         => 16#A2#,
        when Call_Native => 16#C3#);

   procedure Bin (O : Op) is
   begin
      Put_Byte (U64 (Byte_Of (O)));
      N_Insns := N_Insns + 1;
      Popped;        --  two operands in, one result out: net -1
   end Bin;

   procedure Un (O : Op) is
   begin
      Put_Byte (U64 (Byte_Of (O)));
      N_Insns := N_Insns + 1;
   end Un;

   procedure Native_Call (Idx : Natural; NArgs : Natural) is
   begin
      Put_Byte (16#C3#);          --  CALL_NATIVE
      Put_U16 (U16 (Idx));
      Put_Byte (U64 (NArgs));
      N_Insns := N_Insns + 1;
      Popped (NArgs);
   end Native_Call;

   procedure Halt_Program is
   begin
      Put_Byte (16#01#);
      N_Insns := N_Insns + 1;
   end Halt_Program;

   --  ---- labels ----------------------------------------------------------
   procedure Mark (Label_Id : Natural) is
   begin
      if Label_Id = 0 or else Label_Id > Max_Labels then
         raise Wrong_Construct with "bytecode backend: bad label id";
      end if;
      if Labels (Label_Id) >= 0 then
         raise Wrong_Construct with "bytecode backend: label defined twice";
      end if;
      Labels (Label_Id) := Len_Of (Code);
      if Label_Id > N_Labels_Used then
         N_Labels_Used := Label_Id;
      end if;
   end Mark;

   procedure Jump (O : Op; Label_Id : Natural) is
   begin
      if Label_Id = 0 or else Label_Id > Max_Labels then
         raise Wrong_Construct with "bytecode backend: bad label id";
      end if;
      if N_Fixups = Max_Fixups then
         raise Wrong_Construct with "bytecode backend: too many jumps";
      end if;
      Put_Byte (U64 (Byte_Of (O)));
      N_Fixups := N_Fixups + 1;
      Fixups (N_Fixups) := (Pos => Len_Of (Code), Label => Label_Id);
      Put_U32 (0);                --  patched by Encode
      N_Insns := N_Insns + 1;
      if O /= Jmp then
         Popped;                  --  the condition is consumed
      end if;
   end Jump;

   function Insns return Natural is
     (N_Insns);

   --  ---- image -----------------------------------------------------------
   function Padded (S : Unbounded_String) return String is
      T : constant String := To_String (S);
      Pad : constant Natural := (8 - T'Length mod 8) mod 8;
   begin
      return T & (1 .. Pad => Character'Val (0));
   end Padded;

   function Encode return String is
      Proc_Rec   : constant := 24;
      Body_Off   : constant := 4 + Proc_Rec;
      --  CONST pool: words first, then the string area
      Str_Base   : constant Natural := N_Words * 8;
      Str_Offs   : array (1 .. N_Strings) of Natural;
      Pool       : constant Unbounded_String := Words;
      Const_Pay  : Unbounded_String;

      --  resolved label offsets (code-relative)
      Targets    : array (1 .. N_Labels_Used) of Natural := (others => 0);
      Cursor     : Natural := Str_Base;

      Code_Bytes : Unbounded_String := Code;
   begin
      --  string layout: each string follows the previous one
      for I in 1 .. N_Strings loop
         Str_Offs (I) := Cursor;
         Cursor := Cursor + Len_Of (Str_List (I).Text);
      end loop;

      --  patch the pool words that hold a string's offset
      declare
         P : String (1 .. Len_Of (Pool));
      begin
         P := To_String (Pool);
         for I in 1 .. N_Str_Words loop
            declare
               W : constant Natural := Str_Words (I).Word;
               V : constant U64 := U64 (Str_Offs (Str_Words (I).Slot + 1));
            begin
               for K in 0 .. 7 loop
                  P (W * 8 + K + 1) :=
                    Character'Val ((V / 2 ** (8 * K)) mod 256);
               end loop;
            end;
         end loop;
         Const_Pay := To_Unbounded_String (P);
      end;
      for I in 1 .. N_Strings loop
         Const_Pay := Const_Pay & Str_List (I).Text;
      end loop;

      --  resolve jumps: targets are payload-relative (Body_Off + offset)
      for I in 1 .. N_Labels_Used loop
         if Labels (I) < 0 then
            raise Wrong_Construct with "bytecode backend: unresolved label";
         end if;
         Targets (I) := Body_Off + Labels (I);
      end loop;
      declare
         C : String (1 .. Len_Of (Code_Bytes));
      begin
         C := To_String (Code_Bytes);
         for I in 1 .. N_Fixups loop
            declare
               P : constant Natural := Fixups (I).Pos;      --  0-based
               V : constant Natural := Targets (Fixups (I).Label);
            begin
               for K in 0 .. 3 loop
                  C (P + K + 1) :=
                    Character'Val ((V / 256 ** K) mod 256);
               end loop;
            end;
         end loop;
         Code_Bytes := To_Unbounded_String (C);
      end;

      declare
         Payload : Unbounded_String;
      begin
         --  procedure table: one record for the module body
         Payload := Payload & Character'Val (1) & (1 .. 3 => Character'Val (0));
         declare
            Rec : Unbounded_String;
            procedure W32 (V : Natural) is
            begin
               for K in 0 .. 3 loop
                  Rec := Rec & Character'Val ((V / 256 ** K) mod 256);
               end loop;
            end W32;
         begin
            W32 (Body_Off);            --  code_off
            W32 (0);                   --  frame_slots
            Rec := Rec & Character'Val (0) & Character'Val (0);  --  nparams
            Rec := Rec & Character'Val (0) & Character'Val (0);  --  nresults
            W32 (Natural (Integer'Max (Max_Depth, 1)));  --  stack_max
            W32 (0);                   --  stackmap_off
            W32 (0);                   --  line_ref
            Payload := Payload & Rec;
         end;
         Payload := Payload & Code_Bytes;
         declare
            Code_Sec : constant String := Padded (Payload);
            Cst_Sec  : constant String := Padded (Const_Pay);
            Data_Sec : constant String :=
              (1 .. N_Globals * 8 => Character'Val (0));
            N_Sec    : constant := 3;
            Base     : constant Natural := 64 + 24 * N_Sec;
            Off_Code : constant Natural := Base;
            Off_Cst  : constant Natural := Off_Code + Code_Sec'Length;
            Off_Data : constant Natural := Off_Cst + Cst_Sec'Length;
            Total    : constant Natural := Off_Data + Data_Sec'Length;
            Header   : String (1 .. 64);
         begin
            Header (1 .. 4) := "O2CB";
            Header (5 .. 6) := (Character'Val (1), Character'Val (0));
            Header (7 .. 8) := (Character'Val (0), Character'Val (0));
            Header (9 .. 10) := (Character'Val (8), Character'Val (0));
            Header (11 .. 12) := (Character'Val (1), Character'Val (0));
            Header (13 .. 14) :=
              (Character'Val (N_Sec), Character'Val (0));
            Header (15 .. 16) := (Character'Val (0), Character'Val (0));
            declare
               procedure W64 (Pos : Natural; V : Natural) is
                  --  64-bit arithmetic: 2 ** 56 does not fit a Natural
                  --  (32-bit), which is exactly the kind of overflow a
                  --  header writer must not have.
                  use Interfaces;
               begin
                  for K in 0 .. 7 loop
                     Header (Pos + K) :=
                       Character'Val ((U64 (V) / Shift_Left (U64 (1),
                                                         8 * K)) mod 256);
                  end loop;
               end W64;
            begin
               W64 (17, 64);              --  section_table_off
               W64 (25, 0);               --  code_off (also in the table)
               Header (33 .. 40) := (others => Character'Val (0));
               W64 (41, Total);           --  total_size
               W64 (49, 1);               --  flags: has descriptors (unused)
               W64 (57, Body_Off);        --  entry
            end;
            declare
               Table : Unbounded_String;
               procedure Sect (Id, Off, Size : Natural) is
               begin
                  for I in 0 .. 3 loop
                     Table := Table & Character'Val ((Id / 256 ** I) mod 256);
                  end loop;
                  for I in 0 .. 3 loop
                     Table := Table & Character'Val ((1 / 256 ** I) mod 256);
                  end loop;
                  for I in 0 .. 7 loop
                     Table := Table &
                       Character'Val ((U64 (Off)
                                       / Interfaces.Shift_Left (U64 (1),
                                                                8 * I))
                                      mod 256);
                  end loop;
                  for I in 0 .. 7 loop
                     Table := Table &
                       Character'Val ((U64 (Size)
                                       / Interfaces.Shift_Left (U64 (1),
                                                                8 * I))
                                      mod 256);
                  end loop;
               end Sect;
            begin
               Sect (6, Off_Code, Code_Sec'Length);
               Sect (4, Off_Cst, Cst_Sec'Length);
               Sect (5, Off_Data, Data_Sec'Length);
               return Header & To_String (Table) & Code_Sec & Cst_Sec
                 & Data_Sec;
            end;
         end;
      end;
   end Encode;

end O2c_BC;
