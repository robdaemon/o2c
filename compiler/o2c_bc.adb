--  Bytecode emission state for the o2c bytecode backend (M53).
--
--  Sizing note (project rule on fixed tables): the label and fixup tables
--  are sized for the *slice* - a module body with the control flow a test
--  program needs - and raise rather than silently overflow.  They become
--  growable (or per-procedure) when procedures land.
with Ada.Strings.Unbounded;  use Ada.Strings.Unbounded;
with Ada.Unchecked_Conversion;

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
      Proc  : Natural := 0;   --  non-zero: a CALL to this procedure id
   end record;
   Fixups    : array (1 .. Max_Fixups) of Fixup;
   N_Fixups  : Natural := 0;

   --  Sizing note (project rule on fixed tables): procedures and locals are
   --  bounded per module, and the bounds are a compiler-input argument, not
   --  a VM limit - exceeding them is reported, never truncated.  Locals are
   --  counted across all procedures of the module.
   Max_Procs  : constant := 256;
   Max_Locals : constant := 1024;

   type Proc_Entry is record
      Buf_Off     : Natural := 0;   --  where its code starts in the buffer
      Frame_Slots : Natural := 0;
      NParams     : Natural := 0;
      NResults    : Natural := 0;
   end record;

   Procs        : array (1 .. Max_Procs) of Proc_Entry;
   N_Procs_Used : Natural := 0;
   Cur_Proc     : Natural := 0;   --  0 = no procedure open
   Body_Proc    : Natural := 0;   --  the module body, once opened
   Next_Frame   : Natural := 0;   --  next free frame slot of Cur_Proc

   type Local_Entry is record
      Proc : Natural := 0;
      Slot : Natural := 0;
      Name : Unbounded_String;
   end record;

   Locals   : array (1 .. Max_Locals) of Local_Entry;
   N_Locals : Natural := 0;

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
      N_Procs_Used := 0;
      Cur_Proc := 0;
      Body_Proc := 0;
      Next_Frame := 0;
      N_Locals := 0;
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

   function Global_Array (Ada_Name : String; Elements : Natural)
                          return Natural is
      Base : Natural;
   begin
      if not Bytecode_Mode then
         raise Wrong_Construct with "bytecode backend: Global_Array before "
           & "Begin_Mode";
      end if;
      if Elements = 0 then
         raise Wrong_Construct with "bytecode backend: an array needs a "
           & "non-zero length";
      end if;
      for I in 1 .. N_Globals loop
         if To_String (Globals (I).Name) = Ada_Name then
            return I - 1;
         end if;
      end loop;
      if N_Globals + Elements > Max_Globals then
         raise Wrong_Construct with "bytecode backend: too many globals";
      end if;
      Base := N_Globals;
      N_Globals := N_Globals + Elements;
      Globals (Base + 1).Name := To_Unbounded_String (Ada_Name);
      return Base;
   end Global_Array;

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

   function Real_Bits is new Ada.Unchecked_Conversion (Long_Float, U64);

   procedure Push_Real (Value : Long_Float) is
   begin
      Add_Word (Real_Bits (Value));
      Put_Byte (16#2D#);          --  LOAD_CONST_R
      Put_U32 (U32 (N_Words - 1));
      N_Insns := N_Insns + 1;
      Pushed;
   end Push_Real;

   procedure Push_Word (Value : Interfaces.Unsigned_64) is
   begin
      Add_Word (U64 (Value));
      Put_Byte (16#14#);          --  LOAD_CONST
      Put_U32 (U32 (N_Words - 1));
      N_Insns := N_Insns + 1;
      Pushed;
   end Push_Word;

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

   procedure Load_Addr_G (Slot : Natural) is
   begin
      Put_Byte (16#16#);          --  LOAD_ADDR_G
      Put_U32 (U32 (Slot));
      N_Insns := N_Insns + 1;
      Pushed;                     --  the address is a value
   end Load_Addr_G;

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
        when Load_Addr_G  => 16#16#,
        when Load_Idx_I   => 16#1D#,
        when Store_Idx_I  => 16#20#,
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
        when Call_Native => 16#C3#,
        --  docs/obc-image.md: locals at 0x10/0x11, frames at 0xC0-0xC2.
        when Load_L      => 16#10#,
        when Store_L     => 16#11#,
        when Call        => 16#C0#,
        when Ret         => 16#C1#,
        when Ret_Void    => 16#C2#,
        --  docs/obc-image.md: FOR_ENTER_* / FOR_NEXT_* at 0xA4/0xA5.
        when For_Enter_I => 16#A4#,
        when For_Next_I  => 16#A5#,
        --  docs/obc-image.md: SET operators at 0x3D-0x44.
        when Set_Union     => 16#3D#,
        when Set_Intersect => 16#3E#,
        when Set_Diff      => 16#3F#,
        when Set_Symdiff   => 16#40#,
        when Set_Eq        => 16#41#,
        when Set_Ne        => 16#42#,
        when Set_In        => 16#43#,
        when Set_Single    => 16#44#,
        --  docs/obc-image.md: REAL/LONGREAL at 0x80-0x8F.
        when Radd       => 16#80#,
        when Rsub       => 16#81#,
        when Rmul       => 16#82#,
        when Rdiv       => 16#83#,
        when Rneg       => 16#84#,
        when Rabs       => 16#85#,
        when Req        => 16#86#,
        when Rne        => 16#87#,
        when Rlt        => 16#88#,
        when Rle        => 16#89#,
        when Rgt        => 16#8A#,
        when Rge        => 16#8B#,
        when I2R        => 16#8C#,
        when R2I_Round  => 16#8D#,
        when R2I_Trunc  => 16#8E#);

   procedure Trap (Kind : Natural) is
   begin
      Put_Byte (16#06#);          --  TRAP
      Put_Byte (U64 (Kind));
      N_Insns := N_Insns + 1;
   end Trap;

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

   --  ---- procedures and frames -----------------------------------------
   function Begin_Proc (NParams : Natural; NResults : Natural) return Natural is
   begin
      if N_Procs_Used = Max_Procs then
         raise Wrong_Construct with
           "bytecode backend: too many procedures";
      end if;
      if Cur_Proc /= 0 then
         raise Wrong_Construct with
           "bytecode backend: a procedure is already open";
      end if;
      N_Procs_Used := N_Procs_Used + 1;
      Cur_Proc := N_Procs_Used;
      Next_Frame := 0;
      Procs (Cur_Proc) := (Buf_Off    => Length (Code),
                           Frame_Slots => 0,
                           NParams     => NParams,
                           NResults    => NResults);
      return Cur_Proc;
   end Begin_Proc;

   procedure End_Proc is
   begin
      if Cur_Proc = 0 then
         raise Wrong_Construct with
           "bytecode backend: no procedure is open";
      end if;
      Procs (Cur_Proc).Frame_Slots := Next_Frame;
      Cur_Proc := 0;
   end End_Proc;

   procedure Begin_Body is
   begin
      Body_Proc := Begin_Proc (0, 0);
   end Begin_Body;

   function Local (Ada_Name : String) return Natural is
   begin
      if Cur_Proc = 0 then
         raise Wrong_Construct with
           "bytecode backend: a local needs an open procedure";
      end if;
      for I in 1 .. N_Locals loop
         if Locals (I).Proc = Cur_Proc
           and then To_String (Locals (I).Name) = Ada_Name
         then
            return Locals (I).Slot;
         end if;
      end loop;
      if N_Locals = Max_Locals then
         raise Wrong_Construct with "bytecode backend: too many locals";
      end if;
      N_Locals := N_Locals + 1;
      Locals (N_Locals) := (Proc => Cur_Proc,
                            Slot => Next_Frame,
                            Name => To_Unbounded_String (Ada_Name));
      Next_Frame := Next_Frame + 1;
      return Locals (N_Locals).Slot;
   end Local;

   function Local_Count return Natural is
     (Next_Frame);

   function Proc_Open return Boolean is
     (Cur_Proc /= 0);

   function Local_Slot (Ada_Name : String) return Integer is
   begin
      if Cur_Proc = 0 then
         return -1;
      end if;
      for I in 1 .. N_Locals loop
         if Locals (I).Proc = Cur_Proc
           and then To_String (Locals (I).Name) = Ada_Name
         then
            return Integer (Locals (I).Slot);
         end if;
      end loop;
      return -1;
   end Local_Slot;

   procedure Dup_Top is
   begin
      Put_Byte (16#02#);          --  DUP
      N_Insns := N_Insns + 1;
      Pushed (1);
   end Dup_Top;

   procedure Discard is
   begin
      Put_Byte (16#03#);          --  DROP
      N_Insns := N_Insns + 1;
      Popped (1);
   end Discard;

   procedure Load_Local (Slot : Natural) is
   begin
      Put_Byte (16#10#);          --  LOAD_L
      Put_U16 (U16 (Slot));
      N_Insns := N_Insns + 1;
      Pushed (1);
   end Load_Local;

   procedure Store_Local (Slot : Natural) is
   begin
      Put_Byte (16#11#);          --  STORE_L
      Put_U16 (U16 (Slot));
      N_Insns := N_Insns + 1;
      Popped (1);
   end Store_Local;

   procedure Call_Proc (Proc_Id : Natural) is
   begin
      if Proc_Id = 0 or else Proc_Id > N_Procs_Used then
         raise Wrong_Construct with
           "bytecode backend: call to an unknown procedure";
      end if;
      Put_Byte (16#C0#);          --  CALL
      if N_Fixups = Max_Fixups then
         raise Wrong_Construct with "bytecode backend: too many fixups";
      end if;
      N_Fixups := N_Fixups + 1;
      Fixups (N_Fixups) := (Pos => Length (Code), Label => 0,
                            Proc => Proc_Id);
      Put_U32 (0);                --  patched at Encode
      N_Insns := N_Insns + 1;
      Popped (Procs (Proc_Id).NParams);
      Pushed (Procs (Proc_Id).NResults);
   end Call_Proc;

   procedure Return_Value is
   begin
      Put_Byte (16#C1#);          --  RET
      N_Insns := N_Insns + 1;
   end Return_Value;

   --  A label operand inside a FOR opcode is a fixup like any jump target,
   --  patched at Encode: Jump() would emit a separate JMP instruction, which
   --  is not what these opcodes carry.
   procedure For_Fixup (Label_Id : Natural) is
   begin
      if Label_Id = 0 or else Label_Id > Max_Labels then
         raise Wrong_Construct with "bytecode backend: bad label id";
      end if;
      if N_Fixups = Max_Fixups then
         raise Wrong_Construct with "bytecode backend: too many fixups";
      end if;
      N_Fixups := N_Fixups + 1;
      Fixups (N_Fixups) := (Pos => Length (Code), Label => Label_Id,
                            Proc => 0);
      Put_U32 (0);
   end For_Fixup;

   procedure For_Enter (Slot : Natural; Step : Integer;
                        Else_Label : Natural) is
   begin
      Put_Byte (16#A4#);
      Put_U16 (U16 (Slot));
      Put_U32 (U32 (Step) and 16#FFFF_FFFF#);
      For_Fixup (Else_Label);
      N_Insns := N_Insns + 1;
      Popped (2);                 --  from and to are consumed
   end For_Enter;

   procedure For_Next (Slot : Natural; Step : Integer; Limit_Slot : Natural;
                       Body_Label : Natural) is
   begin
      Put_Byte (16#A5#);
      Put_U16 (U16 (Slot));
      Put_U32 (U32 (Step) and 16#FFFF_FFFF#);
      Put_U16 (U16 (Limit_Slot));
      For_Fixup (Body_Label);
      N_Insns := N_Insns + 1;
   end For_Next;

   procedure Return_Void is
   begin
      Put_Byte (16#C2#);          --  RET_VOID
      N_Insns := N_Insns + 1;
   end Return_Void;

   function Code_Offset return Natural is
     (Length (Code));

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
      Fixups (N_Fixups) := (Pos => Len_Of (Code), Label => Label_Id, Proc => 0);
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
      --  Code offsets are relative to the start of the CODE section payload,
      --  which INCLUDES the procedure table (docs/obc-image.md): a
      --  one-procedure image's first instruction is at 4 + 24 = 28, not 0.
      --  These are functions, not constants, so they are evaluated where
      --  they are used - after the module body is opened below.  A constant
      --  object would be evaluated at its declaration, before that, and
      --  report the wrong table size.
      function Code_Base return Natural is
        (4 + N_Procs_Used * Proc_Rec);

      function Body_Offset return Natural is
        (Code_Base + Procs (Body_Proc).Buf_Off);
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
      --  If the front end never opened a procedure then the whole module is
      --  the body: open it now, before any offset is computed or used, so a
      --  one-procedure image keeps the offsets it had before procedures
      --  existed.
      if N_Procs_Used = 0 then
         Begin_Body;
         --  Nothing had been emitted as a procedure, so the code emitted so
         --  far IS this body's code: it starts at buffer offset 0, not at
         --  the current end of the buffer (which is where Begin_Proc, used
         --  for real procedures, would have recorded it).
         Procs (Body_Proc).Buf_Off := 0;
      end if;
      --  The body may hold frame slots too (a FOR loop's variable and its
      --  hidden slots), and the VM bounds-checks frame accesses against
      --  this figure.
      Procs (Body_Proc).Frame_Slots := Next_Frame;

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
         Targets (I) := Code_Base + Labels (I);
      end loop;
      declare
         C : String (1 .. Len_Of (Code_Bytes));
      begin
         C := To_String (Code_Bytes);
         for I in 1 .. N_Fixups loop
            declare
               P : constant Natural := Fixups (I).Pos;      --  0-based
               V : Natural := 0;
            begin
               if Fixups (I).Proc /= 0 then
                  V := Code_Base + Procs (Fixups (I).Proc).Buf_Off;
               else
                  V := Targets (Fixups (I).Label);
               end if;
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
         --  procedure table: n_procs, then one record per procedure.
         --  Procedures are numbered in emission order and the module body is
         --  the last one, which is what the header's entry points at.
         declare
            Rec : Unbounded_String;
            procedure W16 (V : Natural) is
            begin
               Rec := Rec & Character'Val (V mod 256);
               Rec := Rec & Character'Val ((V / 256) mod 256);
            end W16;
            procedure W32 (V : Natural) is
            begin
               for K in 0 .. 3 loop
                  Rec := Rec & Character'Val ((V / 256 ** K) mod 256);
               end loop;
            end W32;
         begin
            W32 (N_Procs_Used);
            Payload := Payload & Rec;
            for P in 1 .. N_Procs_Used loop
               Rec := Null_Unbounded_String;
               W32 (Code_Base + Procs (P).Buf_Off);   --  code_off
               W32 (Procs (P).Frame_Slots);           --  frame_slots
               W16 (Procs (P).NParams);               --  nparams
               W16 (Procs (P).NResults);              --  nresults
               --  stack_max is the module high-water mark: a conservative
               --  bound, which is all the verifier needs.
               W32 (Natural (Integer'Max (Max_Depth, 1)));
               W32 (0);                               --  stackmap_off
               W32 (0);                               --  line_ref
               Payload := Payload & Rec;
            end loop;
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
               W64 (57, Body_Offset);     --  entry
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
