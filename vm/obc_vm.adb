--  o2c bytecode VM: loader/verifier and stack interpreter (M53 thin slice).
--
--  The container is docs/obc-image.md's v1 format.  One deliberate
--  slice simplification, to be replaced by the emitter in M53 proper:
--  CODE carries a real procedure table (n_procs u32, then 24-byte
--  records) but this slice expects exactly one record - the module
--  body - and executes no user procedures.
with Ada.Exceptions;
with Ada.Text_IO;
with Interfaces;
with Ada.Unchecked_Conversion;
with VM_IO;
with System.Storage_Elements;
use type System.Storage_Elements.Integer_Address;

package body OBC_VM is

   subtype Byte is VM_IO.Byte;
   subtype U32 is Interfaces.Unsigned_32;
   subtype U64 is Interfaces.Unsigned_64;
   subtype I64 is Interfaces.Integer_64;

   --  the byte/array types come from VM_IO so file input can be
   --  platform-specific without touching the interpreter
   subtype Byte_Array is VM_IO.Byte_Array;

   --  The image slab and the per-payload copies are HEAP objects, not
   --  stack ones: a guest user stack is 64 pages (256 KiB, the kernel's
   --  User_Stack_Pages), while an image may be up to Max_File.  Declaring
   --  them locally overflowed the stack and trapped on the first store
   --  into Run's frame.
   type Byte_Array_Access is access Byte_Array;

   use type VM_IO.Byte;   --  Byte is VM_IO's type now
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;
   use type Interfaces.Integer_64;

   --  ---- limits of this slice -------------------------------------------
   --
   --  Sizing note (project rule on fixed tables): the slice runs a module
   --  body only - no user procedures, no dynamic objects - so these hold
   --  what a test program needs with headroom, and go away when frames
   --  and ALLOC_NEW land.
   Max_File    : constant := 1_048_576;
   --  A policy limit, not a storage bound.  The operand stack grows on
   --  demand, so this says only how much a program may ask for: it caps what
   --  the verifier will accept as a procedure's Stack_Max, which stops a
   --  runaway image from allocating without limit.  A fixed ceiling here is
   --  what turned a one-slot-per-iteration leak into a bound-dependent
   --  failure instead of a report about depth.
   Max_Stack   : constant := 4096;

   --  Initial allocation only, not ceilings: the frame arrays and the locals
   --  pool both grow by doubling in Push_Frame when a call needs more, so a
   --  program cannot hit these.  They are sized to cover ordinary programs
   --  without a reallocation; depth beyond them costs a copy, not a refusal.
   Max_Frames     : constant := 64;
   Max_VM_Locals  : constant := 1024;
   --  A policy limit on a module's global count, not a storage bound:
   --  Globals is allocated to the image's own N_Globals, so this only says
   --  how many a program may declare.
   Max_Globals : constant := 65536;
   Max_Natives : constant := 5;

   Const_Slot : constant := 8;      --  pool words are 8 bytes
   Proc_Rec   : constant := 24;     --  bytes per procedure table record

   --  ---- little-endian accessors ----------------------------------------
   function LE32 (B : Byte_Array; Off : Natural) return U32 is
     (U32 (B (Off))
      or U32 (B (Off + 1)) * 2 ** 8
      or U32 (B (Off + 2)) * 2 ** 16
      or U32 (B (Off + 3)) * 2 ** 24);

   function LE64 (B : Byte_Array; Off : Natural) return U64 is
      use Interfaces;
      R : U64 := 0;
   begin
      for K in 0 .. 7 loop
         R := R or Shift_Left (U64 (B (Off + K)), 8 * K);
      end loop;
      return R;
   end LE64;

   function LE16 (B : Byte_Array; Off : Natural) return Natural is
     (Natural (B (Off)) + Natural (B (Off + 1)) * 256);

   function To_I64 is new Ada.Unchecked_Conversion (U64, I64);
   --  REAL and LONGREAL share the 8-byte slot and these ops; only the
   --  formatting differs, so a real value is a word reinterpreted.
   function To_R64 is new Ada.Unchecked_Conversion (U64, Long_Float);
   function R64_To_U64 is new Ada.Unchecked_Conversion (Long_Float, U64);
   function To_U64 is new Ada.Unchecked_Conversion (I64, U64);

   --  ---- opcodes this slice implements ----------------------------------
   Op_Nop         : constant := 16#00#;
   Op_Halt        : constant := 16#01#;
   Op_Dup         : constant := 16#02#;
   Op_Drop        : constant := 16#03#;
   Op_Assert_Fail : constant := 16#05#;
   Op_Trap        : constant := 16#06#;
   Op_Load_G      : constant := 16#12#;
   Op_Store_G     : constant := 16#13#;
   Op_Load_Const  : constant := 16#14#;
   Op_Load_L      : constant := 16#10#;
   Op_Store_L     : constant := 16#11#;
   Op_Load_Const_R : constant := 16#2D#;
   Op_Radd       : constant := 16#80#;
   Op_Rsub       : constant := 16#81#;
   Op_Rmul       : constant := 16#82#;
   Op_Rdiv       : constant := 16#83#;
   Op_Rneg       : constant := 16#84#;
   Op_Rabs       : constant := 16#85#;
   Op_Req        : constant := 16#86#;
   Op_Rne        : constant := 16#87#;
   Op_Rlt        : constant := 16#88#;
   Op_Rle        : constant := 16#89#;
   Op_Rgt        : constant := 16#8A#;
   Op_Rge        : constant := 16#8B#;
   Op_I2R        : constant := 16#8C#;
   Op_R2I_Round  : constant := 16#8D#;
   Op_R2I_Trunc  : constant := 16#8E#;
   Op_Load_Addr_G  : constant := 16#16#;
   Op_Load_Idx_I   : constant := 16#1D#;
   Op_Load_Fld_I   : constant := 16#23#;
   Op_Load_Const_P : constant := 16#2C#;
   Op_Guard        : constant := 16#E0#;
   Op_Type_Test    : constant := 16#E1#;
   Op_Desc_Of      : constant := 16#E3#;
   Op_Dispatch     : constant := 16#E2#;
   Op_Alloc_New    : constant := 16#2A#;
   Op_Load_Fld_R   : constant := 16#24#;
   Op_Load_Fld_P   : constant := 16#25#;
   Op_Store_Fld_R  : constant := 16#27#;
   Op_Store_Fld_P  : constant := 16#28#;

   --  ---- heap ------------------------------------------------------------
   --  A bump allocator over a static arena, and no collector: the spec
   --  assumes a non-moving collector, and nothing here frees.  Enough for
   --  NEW and for proving that an allocated object's fields behave like any
   --  other record's.  A guest build would have to move this off the stack
   --  (the guest stack is 256 KiB), hence a package-level arena rather than
   --  a local one, reset at load time so repeated runs start clean.
   --  The arena is not reset between Run calls: the VM is loaded and run
   --  once per process today.  A guest build also has to move it off the
   --  stack (the guest stack is 256 KiB) rather than shrink it.
   Heap_Words : constant := 8192;      --  64 KiB of object bodies

   --  A U64 run that lives on the heap rather than the guest stack, which is
   --  only 256 KiB and is why these were local arrays before.  Indexing an
   --  access to an array reads like indexing the array, so call sites are
   --  unchanged; only the declaration and the growth differ.
   type U64_Array is array (Natural range <>) of U64;
   type U64_Array_Access is access U64_Array;
   type Natural_Array is array (Natural range <>) of Natural;
   type Natural_Array_Access is access Natural_Array;
   Heap       : array (0 .. Heap_Words - 1) of aliased U64;
   --  One bit per arena slot, marking what a collection reached.  Packed
   --  rather than one Boolean per slot: the arena is large next to the guest
   --  stack, and the walk only ever asks about a slot it just reached.
   Mark_Words : constant := (Heap_Words + 63) / 64;
   Marked     : array (0 .. Mark_Words - 1) of U64 := (others => 0);

   --  A freed run is marked by this sentinel in its first arena slot with its
   --  length in slots in the second, which is both how the sweep finds free
   --  space and how the allocator scans for it.  No live object's first slot
   --  can be confused with it: that slot is always its type tag, a small
   --  number.  A run is never shorter than two slots, which any object is.
   Free_Sentinel : constant U64 := 16#F0_0B_1E_5E_ED#;
   Heap_Next  : Natural := 0;
   Op_Store_Fld_I  : constant := 16#26#;
   Op_Store_Idx_I  : constant := 16#20#;
   Op_Set_Union   : constant := 16#3D#;
   Op_Set_Intersect : constant := 16#3E#;
   Op_Set_Diff    : constant := 16#3F#;
   Op_Set_Symdiff : constant := 16#40#;
   Op_Set_Eq      : constant := 16#41#;
   Op_Set_Ne      : constant := 16#42#;
   Op_Set_In      : constant := 16#43#;
   Op_Set_Single  : constant := 16#44#;
   Op_For_Enter   : constant := 16#A4#;
   Op_For_Next    : constant := 16#A5#;
   Op_Call        : constant := 16#C0#;
   Op_Ret         : constant := 16#C1#;
   Op_Ret_Void    : constant := 16#C2#;
   Op_Add         : constant := 16#30#;
   Op_Sub         : constant := 16#31#;
   Op_Mul         : constant := 16#32#;
   Op_Div         : constant := 16#33#;
   Op_Mod         : constant := 16#34#;
   Op_Neg         : constant := 16#35#;
   Op_Abs         : constant := 16#36#;
   Op_Eq          : constant := 16#37#;
   Op_Ne          : constant := 16#38#;
   Op_Lt          : constant := 16#39#;
   Op_Le          : constant := 16#3A#;
   Op_Gt          : constant := 16#3B#;
   Op_Ge          : constant := 16#3C#;
   Op_Btest       : constant := 16#68#;
   Op_Ord         : constant := 16#70#;
   Op_Chr         : constant := 16#71#;
   Op_Jmp         : constant := 16#A0#;
   Op_Jz          : constant := 16#A1#;
   Op_Jnz         : constant := 16#A2#;
   Op_Call_Native : constant := 16#C3#;

   --  Natives of this slice, in the order the emitter will number them:
   --    0 Out.Int (x, w)      1 Out.String (ptr)      2 Out.Ln
   --  Out.String's pointer is an offset into the CONST payload (strings
   --  live in the image, which is why the GC can treat image data as
   --  static roots later).
   Native_Pops : constant array (0 .. Max_Natives - 1) of Natural :=
     (2, 1, 0, 2, 1);

   --  A policy limit, not a storage bound: the proc table is allocated to
   --  the N_Procs the image declares, so this only says how many procedures
   --  a program may have.  The loader still checks it, because N_Procs comes
   --  from the image's header and a malformed one must not be able to demand
   --  an arbitrary allocation.
   Max_Procs   : constant := 256;

   type Proc_Info is record
      Code_Off    : Natural := 0;   --  payload-relative, table included
      Frame_Slots : Natural := 0;
      NParams     : Natural := 0;
      NResults    : Natural := 0;
      Stack_Max   : Natural := 0;
   end record;

   --  The image record allocates its table to the count its header
   --  declares, so this is the unconstrained form to allocate from.
   type Proc_Array is array (Natural range <>) of Proc_Info;
   type Proc_Array_Access is access Proc_Array;

   --  ---- decoded image --------------------------------------------------
   type Image_Info is record
      Entry_Off   : Natural := 0;
      Body_Off    : Natural := 0;   --  code payload offset of the body
      Stack_Max   : Natural := 0;
      N_Globals   : Natural := 0;
      Globals_Off : Natural := 0;   --  offsets into the file
      Consts_Off  : Natural := 0;
      Consts_Len  : Natural := 0;
      Types_Off   : Natural := 0;   --  TYPES payload, when the image has one
      Types_Len   : Natural := 0;
      Code_Off    : Natural := 0;
      Code_Len    : Natural := 0;
      N_Procs     : Natural := 0;
      Body_Proc   : Natural := 0;   --  the one the entry offset names
      Procs       : Proc_Array_Access := null;
      --  The CODE and CONST payloads as 0-based heap copies, shared by the
      --  verifier and the interpreter (see the note in Decode).
      Code        : Byte_Array_Access := null;
      Consts_Copy : Byte_Array_Access := null;
      Types       : Byte_Array_Access := null;   --  0-based TYPES copy
   end record;

   --  An object's type tag sits in the word before it: the descriptor's byte
   --  offset in TYPES, written by ALLOC_NEW.
   function Tag_At (Obj : U64) return Natural is
      W : U64 with Address =>
        System.Storage_Elements.To_Address
          (System.Storage_Elements.Integer_Address (Obj)
           - System.Storage_Elements.Integer_Address (8));
   begin
      return Natural (W mod 16#1_0000_0000#);
   end Tag_At;

   --  Whether an object tagged Tag has dynamic type Ref, or an extension of
   --  it.  The descriptor's base is at +12, after kind, flags, size,
   --  name_ref and the field-list terminator, and walking it is what makes a
   --  test for an ancestor succeed.
   function Descends_From (Img : Image_Info; Tag : Natural;
                           Ref : Natural) return Boolean is
      Cur : Natural := Tag;
   begin
      while Cur /= 0 loop
         if Cur = Ref then
            return True;
         end if;
         if Cur + 15 > Img.Types_Len then
            return False;
         end if;
         --  Cur is a biased reference, so the descriptor starts one byte
         --  earlier than the number suggests; the base it holds is biased
         --  the same way, and zero still means no base.
         Cur := Natural (LE32 (Img.Types.all, Cur - 1 + 12));
      end loop;
      return False;
   end Descends_From;

   --  An allocated object's extent in arena slots: its body rounded up to
   --  whole slots, plus its tag word.  The arena is U64-denominated, so a
   --  size is a slot count and alignment is structural rather than something
   --  an allocator has to arrange.  Every allocation and every walk uses this
   --  one rule, which is what keeps the arena walkable.
   function Alloc_Slots (Size : Natural) return Natural is
     ((Size + 7) / 8 + 1);

   --  How many arena slots an object occupies, its tag word included.  The
   --  sweep walks the arena with this and needs no separate length word: the
   --  tag names the descriptor and the descriptor carries the size.  An
   --  object whose tag is out of range is treated as one slot, so a walk can
   --  still advance past it rather than stopping.
   function Object_Slots (Img : Image_Info; Tag : Natural) return Natural is
      Off : constant Natural := Tag - 1;   --  references are biased
   begin
      if Tag = 0 or else Off + 4 > Img.Types_Len then
         return 1;
      end if;
      return Alloc_Slots (LE16 (Img.Types.all, Off + 2));
   end Object_Slots;

   --  ---- diagnostics ----------------------------------------------------
   procedure Note (Msg : String) is
   begin
      Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Error, "vm: " & Msg);
   end Note;

   procedure Note_At (Msg : String; Off : Natural) is
   begin
      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error,
         "vm: " & Msg & " at code offset" & Natural'Image (Off));
   end Note_At;

   function Image (S : Status) return String is
   begin
      return (case S is
        when Ok              => "ok",
        when Bad_File        => "cannot read image",
        when Bad_Magic       => "not an o2c image (bad magic)",
        when Bad_Version     => "unsupported image version",
        when Bad_Size        => "truncated or inconsistent image",
        when Bad_Section     => "mandatory section missing",
        when Bad_Code        => "malformed code",
        when Bad_Target      => "jump target outside the code payload",
        when Bad_Stack       => "operand-stack depth violation",
        when Bad_Const       => "constant-pool reference out of range",
        when Bad_Native      => "bad native call",
        when Not_Implemented => "opcode not implemented in this slice",
        when Trap_Index      => "index out of range",
        when Trap_Nil        => "NIL dereference",
        when Trap_Guard      => "type guard failure",
        when Trap_Divzero    => "division by zero",
        when Trap_Range      => "value out of range",
        when Assert_Failed   => "assertion failed");
   end Image;

   --  ---- header, sections, procedure table ------------------------------
   function Decode (Data : Byte_Array; Len : Natural; Img : out Image_Info)
                    return Status is
      N_Sections : Natural;
      Table_Off  : Natural;
      Saw_Code   : Boolean := False;
      Saw_Const  : Boolean := False;
      Saw_Data   : Boolean := False;
   begin
      if Len < 64 then
         return Bad_Size;
      end if;
      if Data (0) /= Character'Pos ('O') or else Data (1) /= Character'Pos ('2')
        or else Data (2) /= Character'Pos ('C')
        or else Data (3) /= Character'Pos ('B')
      then
         return Bad_Magic;
      end if;
      --  major must be 1 and (for forward safety) minor must be 0: the
      --  u32 at offset 4 is major | minor << 16 in the little-endian file.
      if LE32 (Data, 4) /= 1 then
         return Bad_Version;
      end if;
      if Data (8) /= 8 or else Data (9) /= 0 then
         return Bad_Size;                     --  ptr_size /= 8
      end if;
      if Data (10) /= 1 or else Data (11) /= 0 then
         return Bad_Size;                     --  endian /= little
      end if;
      if Natural (LE64 (Data, 40)) /= Len then
         return Bad_Size;                     --  total_size mismatch
      end if;

      Img.Entry_Off := Natural (LE64 (Data, 56));

      N_Sections := Natural (Data (12)) + Natural (Data (13)) * 256;
      Table_Off := Natural (LE64 (Data, 16));
      if Table_Off + 24 * N_Sections > Len then
         return Bad_Size;
      end if;

      for I in 0 .. N_Sections - 1 loop
         declare
            Ent  : constant Natural := Table_Off + 24 * I;
            Id   : constant U32 := LE32 (Data, Ent);
            Off  : constant Natural := Natural (LE64 (Data, Ent + 8));
            Size : constant Natural := Natural (LE64 (Data, Ent + 16));
         begin
            if Off + Size > Len then
               return Bad_Size;
            end if;
            case Id is
               when 6 =>
                  Img.Code_Off := Off;
                  Img.Code_Len := Size;
                  Saw_Code := True;
               when 3 =>
                  --  TYPES is optional: an image whose programs allocate
                  --  nothing need not carry descriptors.
                  Img.Types_Off := Off;
                  Img.Types_Len := Size;
               when 4 =>
                  Img.Consts_Off := Off;
                  Img.Consts_Len := Size;
                  Saw_Const := True;
               when 5 =>
                  Img.Globals_Off := Off;
                  Img.N_Globals := Size / Const_Slot;
                  Saw_Data := True;
               when others =>
                  null;                  --  ignore sections we do not know
            end case;
         end;
      end loop;

      if not Saw_Code or else not Saw_Const or else not Saw_Data then
         return Bad_Section;
      end if;
      if Img.Consts_Len mod Const_Slot /= 0
        or else Img.N_Globals > Max_Globals
      then
         return Bad_Size;
      end if;
      if Img.Code_Len < 4 + Proc_Rec then
         return Bad_Code;
      end if;

      --  One 0-based copy per payload, on the HEAP: the guest user stack
      --  is 64 pages (256 KiB) while an image may be up to Max_File, and
      --  a slice of the slab cannot be used directly because it would keep
      --  the slab's 'First (the format's offsets are payload-relative).
      Img.Code := new Byte_Array (0 .. Img.Code_Len - 1);
      Img.Code.all := Data (Img.Code_Off .. Img.Code_Off + Img.Code_Len - 1);
      Img.Consts_Copy := new Byte_Array (0 .. Img.Consts_Len - 1);
      Img.Consts_Copy.all :=
        Data (Img.Consts_Off .. Img.Consts_Off + Img.Consts_Len - 1);
      if Img.Types_Len > 0 then
         Img.Types := new Byte_Array (0 .. Img.Types_Len - 1);
         Img.Types.all :=
           Data (Img.Types_Off .. Img.Types_Off + Img.Types_Len - 1);
      end if;

      declare
         Code : Byte_Array renames Img.Code.all;
         N_Procs : constant Natural := Natural (LE32 (Code, 0));
      begin
         if N_Procs = 0 or else N_Procs > Max_Procs then
            return Bad_Section;
         end if;
         if Img.Code_Len < 4 + N_Procs * Proc_Rec then
            return Bad_Size;
         end if;

         --  One record per procedure: code_off u32, frame_slots u32,
         --  nparams u16, nresults u16, stack_max u32, stackmap_off u32,
         --  line_ref u32.  Code offsets are relative to the start of this
         --  payload, the table included (docs/obc-image.md).
         Img.N_Procs := N_Procs;
         Img.Procs := new Proc_Array (1 .. N_Procs);
         Img.Stack_Max := 0;
         Img.Body_Proc := 0;
         for P in 1 .. N_Procs loop
            declare
               Rec : constant Natural := 4 + (P - 1) * Proc_Rec;
            begin
               Img.Procs (P) :=
                 (Code_Off    => Natural (LE32 (Code, Rec)),
                  Frame_Slots => Natural (LE32 (Code, Rec + 4)),
                  NParams     => LE16 (Code, Rec + 8),
                  NResults    => LE16 (Code, Rec + 10),
                  Stack_Max   => Natural (LE32 (Code, Rec + 12)));
            end;
            if Img.Procs (P).Code_Off > Img.Code_Len then
               return Bad_Target;
            end if;
            if Img.Procs (P).Stack_Max = 0
              or else Img.Procs (P).Stack_Max > Max_Stack
            then
               return Bad_Size;
            end if;
            if Img.Procs (P).Stack_Max > Img.Stack_Max then
               Img.Stack_Max := Img.Procs (P).Stack_Max;
            end if;
            if Img.Procs (P).Code_Off = Img.Entry_Off then
               Img.Body_Proc := P;
            end if;
         end loop;
         if Img.Body_Proc = 0 then
            --  entry has to name a real procedure: the module body.
            return Bad_Target;
         end if;
         Img.Body_Off := Img.Entry_Off;
      end;
      return Ok;
   end Decode;

   --  ---- verification ---------------------------------------------------
   --
   --  Linear verification, as specified for v1: decode the body, check
   --  that every instruction and operand fits, that global/constant
   --  references are in range, that jump targets stay inside the payload,
   --  and that the operand-stack depth never leaves 0 .. Stack_Max.  A
   --  control-flow-aware verifier (per-branch depth and type agreement)
   --  arrives with frames.
   function Verify (Code : Byte_Array; Img : Image_Info) return Status is
      PC    : Natural := Img.Body_Off;
      Depth : Integer := 0;

      function Fits (Off, N : Natural) return Boolean is
        (Off + N <= Code'Length);

      function Depth_Ok return Boolean is
        (Depth >= 0 and then Depth <= Integer (Img.Stack_Max));
   begin
      while PC < Code'Length loop
         case Code (PC) is
            when Op_Nop | Op_Halt =>
               PC := PC + 1;
            when Op_Dup =>
               Depth := Depth + 1;
               PC := PC + 1;
            when Op_Drop =>
               Depth := Depth - 1;
               PC := PC + 1;
            when Op_Trap =>
               if not Fits (PC + 1, 1) then
                  Note_At ("malformed code", PC);
                  return Bad_Code;
               end if;
               if Natural (Code (PC + 1)) > 5 then
                  Note_At ("malformed code", PC);
                  return Bad_Code;
               end if;
               PC := PC + 2;
            when Op_Assert_Fail =>
               if not Fits (PC + 1, 4) then
                  Note_At ("malformed code", PC);
                  return Bad_Code;
               end if;
               if Natural (LE32 (Code, PC + 1)) >= Img.Consts_Len /
                 Const_Slot
               then
                  return Bad_Const;
               end if;
               PC := PC + 5;
            when Op_Load_G =>
               if not Fits (PC + 1, 4)
                 or else Natural (LE32 (Code, PC + 1)) >= Img.N_Globals
               then
                  Note_At ("malformed code", PC);
                  return Bad_Code;
               end if;
               Depth := Depth + 1;
               PC := PC + 5;
            when Op_Store_G =>
               if not Fits (PC + 1, 4)
                 or else Natural (LE32 (Code, PC + 1)) >= Img.N_Globals
               then
                  Note_At ("malformed code", PC);
                  return Bad_Code;
               end if;
               Depth := Depth - 1;
               PC := PC + 5;
            when Op_Load_Const | Op_Load_Const_P =>
               if not Fits (PC + 1, 4) then
                  Note_At ("malformed code", PC);
                  return Bad_Code;
               end if;
               if (Natural (LE32 (Code, PC + 1)) + 1) * Const_Slot
                 > Img.Consts_Len
               then
                  return Bad_Const;
               end if;
               Depth := Depth + 1;
               PC := PC + 5;
            when Op_Add | Op_Sub | Op_Mul | Op_Div | Op_Mod =>
               if Depth < 2 then
                  return Bad_Stack;
               end if;
               Depth := Depth - 1;
               PC := PC + 1;
            when Op_Neg | Op_Abs | Op_Btest | Op_Ord | Op_Chr =>
               if Depth < 1 then
                  return Bad_Stack;
               end if;
               PC := PC + 1;
            when Op_Eq | Op_Ne | Op_Lt | Op_Le | Op_Gt | Op_Ge =>
               if Depth < 2 then
                  return Bad_Stack;
               end if;
               Depth := Depth - 1;
               PC := PC + 1;
            when Op_Jmp =>
               if not Fits (PC + 1, 4) then
                  Note_At ("malformed code", PC);
                  return Bad_Code;
               end if;
               if Natural (LE32 (Code, PC + 1)) >= Code'Length
                 or else Natural (LE32 (Code, PC + 1)) < Img.Body_Off
               then
                  return Bad_Target;
               end if;
               PC := PC + 5;
            when Op_Jz | Op_Jnz =>
               if not Fits (PC + 1, 4) then
                  Note_At ("malformed code", PC);
                  return Bad_Code;
               end if;
               if Natural (LE32 (Code, PC + 1)) >= Code'Length
                 or else Natural (LE32 (Code, PC + 1)) < Img.Body_Off
               then
                  return Bad_Target;
               end if;
               Depth := Depth - 1;
               PC := PC + 5;
            when Op_Call_Native =>
               if not Fits (PC + 1, 3) then
                  Note_At ("malformed code", PC);
                  return Bad_Code;
               end if;
               declare
                  Idx   : constant Natural :=
                    Natural (Code (PC + 1)) + Natural (Code (PC + 2)) * 256;
                  NArgs : constant Natural := Natural (Code (PC + 3));
               begin
                  if Idx >= Max_Natives or else NArgs /= Native_Pops (Idx) then
                     return Bad_Native;
                  end if;
                  Depth := Depth - Integer (NArgs);
               end;
               PC := PC + 4;
            when Op_Load_L | Op_Store_L =>
               --  Frame slot bounds are checked by the interpreter, which
               --  knows the current frame; the linear walk here only needs
               --  the stack effect.
               if not Fits (PC + 2, 1) then
                  Note_At ("malformed code", PC);
                  return Bad_Code;
               end if;
               if Code (PC) = Op_Load_L then
                  Depth := Depth + 1;
               else
                  Depth := Depth - 1;
               end if;
               PC := PC + 3;
            when Op_Call =>
               if not Fits (PC + 1, 4) then
                  Note_At ("malformed code", PC);
                  return Bad_Code;
               end if;
               declare
                  Target : constant Natural := Natural (LE32 (Code, PC + 1));
                  Found  : Boolean := False;
               begin
                  for P in 1 .. Img.N_Procs loop
                     if Img.Procs (P).Code_Off = Target then
                        Found := True;
                        Depth := Depth
                          - Integer (Img.Procs (P).NParams)
                          + Integer (Img.Procs (P).NResults);
                     end if;
                  end loop;
                  if not Found then
                     return Bad_Target;
                  end if;
               end;
               PC := PC + 5;
            when Op_Ret | Op_Ret_Void =>
               --  This walk is linear, and by construction the code after a
               --  return is the next procedure in the payload, so the
               --  frame's depth is not carried across: reset it.  The
               --  interpreter, which actually returns, has no need of this.
               if Depth < 0 then
                  return Bad_Stack;
               end if;
               Depth := 0;
               PC := PC + 1;
            when Op_Load_Addr_G =>
               if not Fits (PC + 1, 4) then
                  Note_At ("malformed code", PC);
                  return Bad_Code;
               end if;
               Depth := Depth + 1;
               PC := PC + 5;
            when Op_Load_Idx_I =>
               if Depth < 2 then
                  return Bad_Stack;
               end if;
               Depth := Depth - 1;
               PC := PC + 1;
            when Op_Store_Idx_I =>
               if Depth < 3 then
                  return Bad_Stack;
               end if;
               Depth := Depth - 2;
               PC := PC + 1;
            when Op_Type_Test | Op_Guard =>
               if not Fits (PC + 1, 4) then
                  Note_At ("malformed code", PC);
                  return Bad_Code;
               end if;
               if Natural (LE32 (Code, PC + 1)) + 4 > Img.Types_Len then
                  Note_At ("malformed code", PC);
                  return Bad_Code;
               end if;
               PC := PC + 5;
            when Op_Dispatch =>
               --  u16 method idx, u8 arg count, u8 result count.  The counts
               --  are static, so the depth change is too.
               if not Fits (PC + 1, 4) then
                  Note_At ("malformed code", PC);
                  return Bad_Code;
               end if;
               declare
                  NArgs : constant Natural := Natural (Code (PC + 3));
                  NRes  : constant Natural := Natural (Code (PC + 4));
               begin
                  if Depth < NArgs + 1 then
                     return Bad_Stack;
                  end if;
                  Depth := Depth - NArgs - 1 + NRes;
               end;
               PC := PC + 5;
            when Op_Desc_Of =>
               PC := PC + 1;
            when Op_Alloc_New =>
               if not Fits (PC + 1, 4) then
                  Note_At ("malformed code", PC);
                  return Bad_Code;
               end if;
               --  The reference is a byte offset into TYPES, where kind,
               --  flags and the object size are the first four bytes.
               if Natural (LE32 (Code, PC + 1)) + 4 > Img.Types_Len then
                  Note_At ("malformed code", PC);
                  return Bad_Code;
               end if;
               Depth := Depth + 1;
               PC := PC + 5;
            when Op_Load_Fld_I | Op_Load_Fld_R | Op_Load_Fld_P =>
               if not Fits (PC + 1, 2) then
                  Note_At ("malformed code", PC);
                  return Bad_Code;
               end if;
               if Depth < 1 then
                  return Bad_Stack;
               end if;
               PC := PC + 3;
            when Op_Store_Fld_I | Op_Store_Fld_R | Op_Store_Fld_P =>
               if not Fits (PC + 1, 2) then
                  Note_At ("malformed code", PC);
                  return Bad_Code;
               end if;
               if Depth < 2 then
                  return Bad_Stack;
               end if;
               Depth := Depth - 2;
               PC := PC + 3;
            --  REAL and LONGREAL share the 8-byte slot, so these move words
            --  and the depth is all the verifier tracks.
            when Op_Load_Const_R =>
               if not Fits (PC + 1, 4) then
                  Note_At ("malformed code", PC);
                  return Bad_Code;
               end if;
               Depth := Depth + 1;
               PC := PC + 5;
            when Op_Radd | Op_Rsub | Op_Rmul | Op_Rdiv
               | Op_Req | Op_Rne | Op_Rlt | Op_Rle | Op_Rgt | Op_Rge =>
               if Depth < 2 then
                  return Bad_Stack;
               end if;
               Depth := Depth - 1;
               PC := PC + 1;
            when Op_Rneg | Op_Rabs | Op_I2R | Op_R2I_Round | Op_R2I_Trunc =>
               if Depth < 1 then
                  return Bad_Stack;
               end if;
               PC := PC + 1;
            --  The verifier models the operand stack as Depth, not SP: it
            --  does not keep values, only their count.
            when Op_Set_Union | Op_Set_Intersect | Op_Set_Diff
               | Op_Set_Symdiff | Op_Set_Eq | Op_Set_Ne | Op_Set_In =>
               if Depth < 2 then
                  return Bad_Stack;
               end if;
               Depth := Depth - 1;
               PC := PC + 1;
            when Op_Set_Single =>
               if Depth < 1 then
                  return Bad_Stack;
               end if;
               PC := PC + 1;
            when Op_For_Enter =>
               --  u16 var slot, i32 step, u16 limit slot, u32 else target.
               --  from and to are consumed; frame-slot bounds are the
               --  interpreter's business.
               if not Fits (PC + 3, 10) then
                  Note_At ("malformed code", PC);
                  return Bad_Code;
               end if;
               if Natural (LE32 (Code, PC + 9)) > Code'Length then
                  return Bad_Target;
               end if;
               Depth := Depth - 2;
               PC := PC + 13;
            when Op_For_Next =>
               --  u16 var slot, i32 step, u16 limit slot, u32 body target.
               if not Fits (PC + 3, 10) then
                  Note_At ("malformed code", PC);
                  return Bad_Code;
               end if;
               if Natural (LE32 (Code, PC + 9)) > Code'Length then
                  return Bad_Target;
               end if;
               PC := PC + 13;
            when others =>
               Note_At ("verification stopped: opcode not implemented in this "
                   & "slice", PC);
               return Not_Implemented;
         end case;
         if not Depth_Ok then
            Note_At ("operand-stack depth violation", PC);
            return Bad_Stack;
         end if;
      end loop;
      return Ok;
   end Verify;

   --  ---- natives --------------------------------------------------------
   function Call_Native (Idx : Natural; Arg1, Arg2 : U64;
                         Consts : Byte_Array) return Status is
      use Ada.Text_IO;

      procedure Put_Int (V : I64; Width : Natural) is
         Txt : constant String := I64'Image (V);
         Beg : Positive := Txt'First;
         Len : Natural;
      begin
         while Beg <= Txt'Last and then Txt (Beg) = ' ' loop
            Beg := Beg + 1;
         end loop;
         Len := Txt'Last - Beg + 1;
         for I in 1 .. Width - Len loop
            Put (' ');
         end loop;
         Put (Txt (Beg .. Txt'Last));
      end Put_Int;

      procedure Put_Str (Off : Natural) is
         K : Natural := Off;
      begin
         if Off > Consts'Length then
            return;
         end if;
         while K < Consts'Length and then Consts (K) /= 0 loop
            Put (Character'Val (Consts (K)));
            K := K + 1;
         end loop;
      end Put_Str;
   begin
      case Idx is
         when 0 =>
            Put_Int (To_I64 (Arg1),
                     Natural'Max (0, Natural (To_I64 (Arg2))));
            return Ok;
         when 1 =>
            Put_Str (Natural (Arg1));
            return Ok;
         when 3 =>
            --  Out.Real: the integer part, a dot, then three zero-padded
            --  digits - mirroring O2c_Put_Real in the Ada backend so the
            --  two print the same thing.
            declare
               V   : constant Long_Float := To_R64 (Arg1);
               IP  : constant I64 := (if V < 0.0
                                      then I64 (V - 0.5) + 1
                                      else I64 (V - 0.5));
               FR  : I64 := I64 (abs (V - Long_Float (IP)) * 1000.0);
               Ip2 : I64 := IP;
            begin
               if FR > 999 then
                  Ip2 := Ip2 + 1;
                  FR := 0;
               end if;
               Put_Int (Ip2, 0);
               Put ('.');
               Put (Character'Val (48 + Integer (FR / 100)));
               Put (Character'Val (48 + Integer ((FR / 10) mod 10)));
               Put (Character'Val (48 + Integer (FR mod 10)));
               return Ok;
            end;
         when 4 =>
            --  Out.Char: one character.  A char is an integer code here, so
            --  a value outside 0 .. 255 is a runtime error rather than a
            --  silently masked byte.
            declare
               V : constant I64 := To_I64 (Arg1);
            begin
               if V < 0 or else V > 255 then
                  return Trap_Range;
               end if;
               Put (Character'Val (Integer (V)));
               return Ok;
            end;
         when 2 =>
            New_Line;
            return Ok;
         when others =>
            return Bad_Native;
      end case;
   end Call_Native;

   --  ---- interpreter ----------------------------------------------------
   function Execute (Data : Byte_Array; Img : Image_Info) return Status is
      Code   : Byte_Array renames Img.Code.all;
      Consts : Byte_Array renames Img.Consts_Copy.all;
      Stack   : U64_Array_Access := new U64_Array (0 .. Max_Stack - 1);
      --  The collector's root set is the *live prefix* of each of these three
      --  arrays, never the whole array: Stack (0 .. SP - 1), Locals
      --  (0 .. Locals_Used - 1) and Globals (0 .. Img.N_Globals - 1).  Slots
      --  above SP are dead, and a stale value there must not keep an object
      --  alive - being able to say so is the whole reason this VM collects
      --  precisely.  Each word is still validated as an arena object before
      --  being followed, so a scalar that happens to look like an address can
      --  only retain an object, never free a live one.
      --  Sized by the image, not by a ceiling: the loader has already
      --  rejected anything past Max_Globals, so this is exactly what the
      --  program declared and no more.
      Globals : constant U64_Array_Access :=
        new U64_Array (0 .. Natural'Max (Img.N_Globals, 1) - 1);
      SP      : Natural := 0;
      PC      : Natural := Img.Body_Off;

      procedure Push (V : U64) is
      begin
         if SP = Stack'Length then
            --  Doubling: amortised, and the only place the operand stack
            --  ever grows.  A program that recurses deeply or nests
            --  expressions deeply is no longer capped by a compile-time
            --  ceiling, only by Max_Stack and then by memory.
            declare
               Bigger : constant U64_Array_Access :=
                 new U64_Array (0 .. Stack'Length * 2 - 1);
            begin
               Bigger (0 .. Stack'Length - 1) := Stack.all;
               Stack := Bigger;
            end;
         end if;
         Stack (SP) := V;
         SP := SP + 1;
      end Push;

      function Pop return U64 is
      begin
         SP := SP - 1;
         return Stack (SP);
      end Pop;

      function Top return U64 is
        (Stack (SP - 1));


      --  Frames.  Frame 0 is the module body; a CALL pushes the next frame
      --  at the current top of the locals pool, so slot i of the current
      --  frame lives at Locals (Frame_Base (Cur_Frame) + i), and the callee's
      --  parameter slots are the lowest slots of its frame.
      Locals      : U64_Array_Access := new U64_Array (0 .. Max_VM_Locals - 1);
      --  Frame 0's base is only written when a CALL pushes a frame, so a
      --  program with no calls reads it before any store.  The old local
      --  array got zero from its initialiser; an access does not, so the
      --  aggregate is spelled out rather than relying on a default that
      --  never arrives.
      Frame_Base  : Natural_Array_Access :=
        new Natural_Array'(0 .. Max_Frames - 1 => 0);
      --  Written for frame 0 before any read, so the default never
      --  mattered here - but it is spelled out anyway, since the same
      --  omission made Frame_Base read an uninitialised slot.
      Frame_Slots : Natural_Array_Access :=
        new Natural_Array'(0 .. Max_Frames - 1 => 0);
      Return_PC   : Natural_Array_Access :=
        new Natural_Array'(0 .. Max_Frames - 1 => 0);
      Cur_Frame   : Natural := 0;
      Locals_Used : Natural := 0;

      --  Push the frame for Callee, so the body resumes at the instruction
      --  after the call.  CALL and DISPATCH each built this themselves, which
      --  meant every change to frames had to be made twice - and the two
      --  copies had already drifted apart in what they reported.  False means
      --  the call could not be set up, with the reason already noted.
      function Push_Frame (Callee : Natural) return Boolean is
         Base : constant Natural := Locals_Used;
      begin
         if Cur_Frame + 1 >= Frame_Slots'Length then
            --  Grow rather than refuse.  Call depth is the program's own
            --  business, and all three arrays are indexed by frame number so
            --  they grow together.
            declare
               Cap       : constant Natural := Frame_Slots'Length * 2;
               Old       : constant Natural := Frame_Slots'Length;
               New_Base  : constant Natural_Array_Access :=
                 new Natural_Array'(0 .. Cap - 1 => 0);
               New_Slots : constant Natural_Array_Access :=
                 new Natural_Array'(0 .. Cap - 1 => 0);
               New_PC    : constant Natural_Array_Access :=
                 new Natural_Array'(0 .. Cap - 1 => 0);
            begin
               New_Base  (0 .. Old - 1) := Frame_Base.all;
               New_Slots (0 .. Old - 1) := Frame_Slots.all;
               New_PC    (0 .. Old - 1) := Return_PC.all;
               Frame_Base  := New_Base;
               Frame_Slots := New_Slots;
               Return_PC   := New_PC;
            end;
         end if;
         if Base + Img.Procs (Callee).Frame_Slots > Locals'Length then
            --  The pool is sized by the call chain, so grow it too.  Existing
            --  frames keep their slots, which is why the copy starts at zero.
            declare
               Cap   : Natural := Locals'Length;
               Old   : constant Natural := Locals'Length;
               Newer : U64_Array_Access;
            begin
               while Cap < Base + Img.Procs (Callee).Frame_Slots loop
                  Cap := Cap * 2;
               end loop;
               Newer := new U64_Array (0 .. Cap - 1);
               Newer (0 .. Old - 1) := Locals.all;
               Locals := Newer;
            end;
         end if;
         for K in reverse 0 .. Img.Procs (Callee).NParams - 1 loop
            Locals (Base + K) := Pop;
         end loop;
         Return_PC (Cur_Frame) := PC + 5;
         Cur_Frame := Cur_Frame + 1;
         Frame_Base (Cur_Frame) := Base;
         Frame_Slots (Cur_Frame) := Img.Procs (Callee).Frame_Slots;
         Locals_Used := Base + Img.Procs (Callee).Frame_Slots;
         return True;
      end Push_Frame;

      Op : Byte;
      --  The mark phase, nested inside Execute because that is what makes the
      --  roots precise: the live prefixes of the operand stack, the frame
      --  slots and the globals are readable here and nowhere else.  It must
      --  sit in the declarative part, since a collection runs from inside
      --  ALLOC_NEW and these are the only places those roots exist.
      Heap_Lo : constant U64 := U64 (System.Storage_Elements.To_Integer
                                       (Heap (0)'Address));
      Heap_Hi : constant U64 := U64 (System.Storage_Elements.To_Integer
                                       (Heap (Heap_Words - 1)'Address));

      --  A worklist rather than recursion: a deep structure would otherwise
      --  recurse one frame per object into a 256 KiB guest stack.
      Mark_Done  : Boolean := True;   --  cleared if marking had to give up
      Mark_Stack : array (0 .. 255) of Natural := (others => 0);
      Mark_Count : Natural := 0;

      function Marked_At (Slot : Natural) return Boolean is
        ((Marked (Slot / 64) and U64 (2 ** (Slot mod 64))) /= 0);

      procedure Mark_Set (Slot : Natural) is
      begin
         Marked (Slot / 64) :=
           Marked (Slot / 64) or U64 (2 ** (Slot mod 64));
      end Mark_Set;

      --  Take a word from the stack, a frame or an object body, and if it
      --  really names a live arena object, mark it and queue it.  A word that
      --  merely resembles an address costs a mark, never a mistaken free.
      procedure Mark_Word (W : U64) is
         Slot : Natural;
      begin
         if W < Heap_Lo or else W >= Heap_Hi
           or else (W - Heap_Lo) mod 8 /= 0
         then
            return;
         end if;
         Slot := Natural ((W - Heap_Lo) / 8);
         if Slot >= Heap_Next or else Marked_At (Slot) then
            return;                     --  free space, or already reached
         end if;
         Mark_Set (Slot);
         if Mark_Count = Mark_Stack'Length then
            --  Out of worklist.  Give up on this collection and free nothing
            --  rather than risk reclaiming something still reachable.
            Mark_Done := False;
         else
            Mark_Stack (Mark_Count) := Slot;
            Mark_Count := Mark_Count + 1;
         end if;
      end Mark_Word;

      procedure Mark_All is
         Slot : Natural;
         Tag  : Natural;
         Off  : Natural;
      begin
         Marked     := (others => 0);
         Mark_Count := 0;
         Mark_Done  := True;
         for K in 0 .. SP - 1 loop
            Mark_Word (Stack (K));
         end loop;
         for K in 0 .. Locals_Used - 1 loop
            Mark_Word (Locals (K));
         end loop;
         for K in 0 .. Img.N_Globals - 1 loop
            Mark_Word (Globals (K));
         end loop;
         while Mark_Count > 0 and then Mark_Done loop
            Mark_Count := Mark_Count - 1;
            Slot := Mark_Stack (Mark_Count);
            Tag  := Tag_At (Heap (Slot));
            Off  := Tag - 1;
            if Off + 4 <= Img.Types_Len
              and then Img.Types.all (Off + 1) mod 2 = 1
            then
               --  has_ptrs: this body may hold pointers, so every word of it
               --  is a candidate.  The tag word is not part of the body.
               for K in 0 .. Object_Slots (Img, Tag) - 2 loop
                  Mark_Word (Heap (Slot + K));
               end loop;
            end if;
         end loop;
      end Mark_All;

      --  Return every unmarked object to the arena.  The walk steps by object
      --  extent, taken from each object's tag, and over free runs by their
      --  recorded length; a freed run merges with one following it if there
      --  is one, so a program that keeps freeing does not fragment the arena
      --  indefinitely.  Merging is forward only, which is enough for the
      --  common case of neighbours freed in the same pass.
      procedure Sweep is
         Slot : Natural := 0;
         Tag  : Natural;
         Len  : Natural;
      begin
         while Slot < Heap_Next loop
            if Heap (Slot) = Free_Sentinel then
               Slot := Slot + Natural (Heap (Slot + 1));
            else
               Tag := Natural (Heap (Slot));
               Len := Object_Slots (Img, Tag);
               if not Marked_At (Slot) then
                  if Slot + Len < Heap_Next
                    and then Heap (Slot + Len) = Free_Sentinel
                  then
                     Len := Len + Natural (Heap (Slot + Len + 1));
                  end if;
                  Heap (Slot) := Free_Sentinel;
                  Heap (Slot + 1) := U64 (Len);
               end if;
               Slot := Slot + Len;
            end if;
         end loop;
      end Sweep;

      --  The first free run large enough, or an impossible slot when there is
      --  none.  This is the whole of the free list: runs are discoverable by
      --  walking the arena, so no separate structure can fall out of step
      --  with the space it describes.
      function Free_Fit (Need : Natural) return Natural is
         Slot : Natural := 0;
         Len  : Natural;
      begin
         while Slot < Heap_Next loop
            if Heap (Slot) = Free_Sentinel then
               Len := Natural (Heap (Slot + 1));
               if Len >= Need then
                  return Slot;
               end if;
               Slot := Slot + Len;
            else
               Slot := Slot + Object_Slots (Img, Natural (Heap (Slot)));
            end if;
         end loop;
         return Heap_Words + 1;
      end Free_Fit;

   begin
      --  module globals come from the DATA section (their initial values)
      for I in 0 .. Img.N_Globals - 1 loop
         Globals (I) := LE64 (Data, Img.Globals_Off + I * Const_Slot);
      end loop;

      Frame_Slots (0) := Img.Procs (Img.Body_Proc).Frame_Slots;
      Locals_Used := Frame_Slots (0);
      Cur_Frame := 0;

      loop
         if PC >= Code'Length then
            Note_At ("ran past the end of the code payload", PC);
            return Bad_Code;
         end if;
         Op := Code (PC);
         case Op is
            when Op_Nop =>
               PC := PC + 1;
            when Op_Halt =>
               return Ok;
            when Op_Dup =>
               Push (Top);
               PC := PC + 1;
            when Op_Drop =>
               --  a stack adjustment: the slot is not read
               SP := SP - 1;
               PC := PC + 1;
            when Op_Load_G =>
               Push (Globals (Natural (LE32 (Code, PC + 1))));
               PC := PC + 5;
            when Op_Store_G =>
               Globals (Natural (LE32 (Code, PC + 1))) := Pop;
               PC := PC + 5;
            when Op_Load_Const | Op_Load_Const_P =>
               Push (LE64 (Consts,
                           Natural (LE32 (Code, PC + 1)) * Const_Slot));
               PC := PC + 5;
            when Op_Add | Op_Sub | Op_Mul =>
               declare
                  B : constant I64 := To_I64 (Pop);
                  A : constant I64 := To_I64 (Pop);
               begin
                  Push (To_U64 (case Op is
                                  when Op_Add => A + B,
                                  when Op_Sub => A - B,
                                  when others => A * B));
               end;
               PC := PC + 1;
            when Op_Div | Op_Mod =>
               declare
                  B : constant I64 := To_I64 (Pop);
                  A : constant I64 := To_I64 (Pop);
               begin
                  if B = 0 then
                     Note_At ("division by zero", PC);
                     return Trap_Divzero;
                  end if;
                  Push (To_U64 (if Op = Op_Div then A / B else A rem B));
               end;
               PC := PC + 1;
            when Op_Neg =>
               Push (To_U64 (-To_I64 (Pop)));
               PC := PC + 1;
            when Op_Abs =>
               declare
                  A : constant I64 := To_I64 (Pop);
               begin
                  Push (To_U64 (abs A));
               end;
               PC := PC + 1;
            when Op_Eq | Op_Ne | Op_Lt | Op_Le | Op_Gt | Op_Ge =>
               declare
                  B : constant I64 := To_I64 (Pop);
                  A : constant I64 := To_I64 (Pop);
                  R : constant Boolean :=
                    (case Op is
                       when Op_Eq => A = B,
                       when Op_Ne => A /= B,
                       when Op_Lt => A < B,
                       when Op_Le => A <= B,
                       when Op_Gt => A > B,
                       when others => A >= B);
               begin
                  Push (if R then 1 else 0);
               end;
               PC := PC + 1;
            when Op_Btest | Op_Ord =>
               --  BOOLEAN is already 0/1 and CHAR shares INTEGER's slot
               PC := PC + 1;
            when Op_Chr =>
               declare
                  V : constant I64 := To_I64 (Pop);
               begin
                  if V < 0 or else V > 255 then
                     Note_At ("CHR argument out of range", PC);
                     return Trap_Range;
                  end if;
                  Push (To_U64 (V));
               end;
               PC := PC + 1;
            when Op_Jmp =>
               PC := Natural (LE32 (Code, PC + 1));
            when Op_Jz | Op_Jnz =>
               declare
                  Target : constant Natural := Natural (LE32 (Code, PC + 1));
                  V      : constant U64 := Pop;
                  Taken  : constant Boolean :=
                    (if Op = Op_Jz then V = 0 else V /= 0);
               begin
                  if Taken then
                     PC := Target;
                  else
                     PC := PC + 5;
                  end if;
               end;
            when Op_Trap =>
               declare
                  Kind : constant Natural := Natural (Code (PC + 1));
               begin
                  return (case Kind is
                            when 0 => Trap_Index,
                            when 1 => Trap_Nil,
                            when 2 => Trap_Guard,
                            when 3 => Trap_Divzero,
                            when others => Trap_Range);
               end;
            when Op_Assert_Fail =>
               Note ("assertion failed");
               return Assert_Failed;
            when Op_Call_Native =>
               declare
                  Idx   : constant Natural :=
                    Natural (Code (PC + 1)) + Natural (Code (PC + 2)) * 256;
                  NArgs : constant Natural := Natural (Code (PC + 3));
                  A2    : U64 := 0;
                  A1    : U64 := 0;
                  St    : Status;
               begin
                  if NArgs = 2 then
                     A2 := Pop;
                  end if;
                  if NArgs >= 1 then
                     A1 := Pop;
                  end if;
                  St := Call_Native (Idx, A1, A2, Consts);
                  if St /= Ok then
                     Note_At ("native call failed", PC);
                     return St;
                  end if;
               end;
               PC := PC + 4;
            when Op_Load_L | Op_Store_L =>
               if PC + 2 >= Code'Length then
                  return Bad_Code;
               end if;
               declare
                  Slot : constant Natural :=
                    Natural (Code (PC + 1)) + Natural (Code (PC + 2)) * 256;
                  Addr : constant Natural := Frame_Base (Cur_Frame) + Slot;
               begin
                  if Slot >= Frame_Slots (Cur_Frame) then
                     Note_At ("local slot out of range", PC);
                     return Bad_Stack;
                  end if;
                  if Op = Op_Load_L then
                     if SP >= Max_Stack then
                        return Bad_Stack;
                     end if;
                     Push (Locals (Addr));
                  else
                     if SP = 0 then
                        return Bad_Stack;
                     end if;
                     Locals (Addr) := Pop;
                  end if;
               end;
               PC := PC + 3;

            when Op_Call =>
               if PC + 4 >= Code'Length then
                  return Bad_Code;
               end if;
               declare
                  Target : constant Natural := Natural (LE32 (Code, PC + 1));
                  Callee : Natural := 0;
               begin
                  for P in 1 .. Img.N_Procs loop
                     if Img.Procs (P).Code_Off = Target then
                        Callee := P;
                     end if;
                  end loop;
                  if Callee = 0 then
                     Note_At ("call target is not a procedure", PC);
                     return Bad_Target;
                  end if;
                  if SP < Img.Procs (Callee).NParams then
                     return Bad_Stack;
                  end if;
                  if not Push_Frame (Callee) then
                     return Bad_Stack;
                  end if;
                  PC := Target;
               end;

            when Op_Ret =>
               if Cur_Frame = 0 or else SP = 0 then
                  return Bad_Stack;
               end if;
               declare
                  Result : constant U64 := Pop;
               begin
                  Locals_Used := Frame_Base (Cur_Frame);
                  Cur_Frame := Cur_Frame - 1;
                  PC := Return_PC (Cur_Frame);
                  Push (Result);
               end;

            when Op_Ret_Void =>
               if Cur_Frame = 0 then
                  return Bad_Stack;
               end if;
               Locals_Used := Frame_Base (Cur_Frame);
               Cur_Frame := Cur_Frame - 1;
               PC := Return_PC (Cur_Frame);

            when Op_Load_Addr_G =>
               --  The address of a global slot.  An array is a run of them,
               --  and this is how an indexed access reaches the run; the
               --  emitter bounds-checks a fixed array, since an address
               --  carries no length.
               if PC + 4 >= Code'Length then
                  return Bad_Code;
               end if;
               Push (U64 (System.Storage_Elements.To_Integer
                            (Globals (Natural (LE32 (Code, PC + 1)))
                               'Address)));
               PC := PC + 5;
            when Op_Load_Idx_I =>
               declare
                  Idx : constant U64 := Pop;
                  Bas : constant U64 := Pop;
                  V   : U64 with Address =>
                    System.Storage_Elements.To_Address
                      (System.Storage_Elements.Integer_Address (Bas)
                       + System.Storage_Elements.Integer_Address (Idx)
                         * System.Storage_Elements.Integer_Address (8));
               begin
                  Push (V);
               end;
               PC := PC + 1;
            when Op_Store_Idx_I =>
               declare
                  Val : constant U64 := Pop;
                  Idx : constant U64 := Pop;
                  Bas : constant U64 := Pop;
                  V   : U64 with Address =>
                    System.Storage_Elements.To_Address
                      (System.Storage_Elements.Integer_Address (Bas)
                       + System.Storage_Elements.Integer_Address (Idx)
                         * System.Storage_Elements.Integer_Address (8));
               begin
                  V := Val;
               end;
               PC := PC + 1;

            when Op_Dispatch =>
               --  u16 method idx, u8 arg count, u8 result count.  self sits
               --  under the arguments, so the arity is what locates it; the
               --  frame is then set up exactly as CALL sets it up.
               if PC + 4 >= Code'Length then
                  return Bad_Code;
               end if;
               declare
                  Idx   : constant Natural :=
                    Natural (Code (PC + 1)) + Natural (Code (PC + 2)) * 256;
                  NArgs : constant Natural := Natural (Code (PC + 3));
                  Self  : U64;
                  Tag   : Natural;
                  Table : Natural;
                  N_M   : Natural;
                  Callee : Natural;
               begin
                  if SP < NArgs + 1 then
                     return Bad_Stack;
                  end if;
                  Self := Stack (SP - 1 - NArgs);
                  if Self = 0 then
                     Note_At ("dispatch on NIL", PC);
                     return Bad_Stack;
                  end if;
                  Tag := Tag_At (Self);
                  if Tag = 0 or else Tag + 16 >= Img.Types_Len then
                     Note_At ("dispatch on an object with no type tag", PC);
                     return Bad_Code;
                  end if;
                  Table := Natural (LE32 (Img.Types.all, Tag - 1 + 16));
                  if Table = 0 then
                     Note_At ("dispatch on a type with no method table", PC);
                     return Bad_Code;
                  end if;
                  N_M := Natural (LE32 (Img.Types.all, Table - 1));
                  if Idx >= N_M then
                     Note_At ("dispatch index past the method table", PC);
                     return Bad_Code;
                  end if;
                  Callee := Natural
                    (LE32 (Img.Types.all, Table - 1 + 4 + Idx * 4));
                  if Callee = 0 or else Callee > Img.N_Procs then
                     Note_At ("dispatch resolved to no procedure", PC);
                     return Bad_Code;
                  end if;
                  if not Push_Frame (Callee) then
                     return Bad_Stack;
                  end if;
                  PC := Img.Procs (Callee).Code_Off;
               end;
            when Op_Type_Test =>
               declare
                  Obj : constant U64 := Pop;
                  Ref : constant Natural :=
                    Natural (LE32 (Code, PC + 1));
               begin
                  --  NIL has no dynamic type.  Oberon leaves the result
                  --  undefined and most implementations trap; false is the
                  --  total answer, and GUARD checks NIL itself so it never
                  --  depends on this.
                  Push ((if Obj = 0 then 0
                         else (if Descends_From (Img, Tag_At (Obj), Ref)
                               then 1 else 0)));
               end;
               PC := PC + 5;
            when Op_Guard =>
               declare
                  Obj : constant U64 := Pop;
                  Ref : constant Natural :=
                    Natural (LE32 (Code, PC + 1));
               begin
                  if Obj = 0 then
                     Push (0);          --  NIL passes, per the spec
                  elsif Descends_From (Img, Tag_At (Obj), Ref) then
                     Push (Obj);        --  the pointer itself, not the tag
                  else
                     Note ("type guard failed");
                     return Trap_Guard;
                  end if;
               end;
               PC := PC + 5;
            when Op_Desc_Of =>
               declare
                  Obj : constant U64 := Pop;
               begin
                  Push (U64 (System.Storage_Elements.To_Integer
                               (Img.Types (Tag_At (Obj) - 1)'Address)));
               end;
               PC := PC + 1;
            when Op_Alloc_New =>
               --  A zeroed body from the arena, sized by the TYPES descriptor the
               --  operand names.  The push is the address the field and indexed
               --  accesses already know how to use, so an allocated record behaves
               --  exactly like one on the globals run.
               declare
                  --  References are the descriptor's offset plus one, so 0
                  --  can mean none; the offset is what indexes TYPES.
                  Ref   : constant Natural :=
                    Natural (LE32 (Code, PC + 1)) - 1;
                  Size  : constant Natural := LE16 (Img.Types.all, Ref + 2);
                  --  The tag word is part of the extent, so the body is one
                  --  slot less than Alloc_Slots reports.
                  Words : constant Natural := Alloc_Slots (Size) - 1;
                  Need  : constant Natural := Words + 1;
                  Fit   : Natural := Free_Fit (Need);
                  Base  : Natural;
                  Left  : Natural;
               begin
                  if Fit > Heap_Words
                    and then Heap_Next + Need > Heap_Words
                  then
                     --  The one collection point.  Allocation happens
                     --  nowhere else, so the collector runs here: mark from
                     --  the roots, sweep what is unreachable back into free
                     --  runs, and look again.  Collecting only when free
                     --  space is short is what keeps a steady-state loop
                     --  from collecting on every allocation.
                     Mark_All;
                     Sweep;
                     Fit := Free_Fit (Need);
                  end if;
                  if Fit <= Heap_Words then
                     --  Take the head of the run and leave the remainder as
                     --  its own run.  A single leftover slot cannot hold a
                     --  sentinel and a length, so it is absorbed, which is
                     --  why merging on the sweep matters.
                     Base := Fit;
                     Left := Natural (Heap (Fit + 1)) - Need;
                     if Left >= 2 then
                        Heap (Fit + Need) := Free_Sentinel;
                        Heap (Fit + Need + 1) := U64 (Left);
                     end if;
                  elsif Heap_Next + Need <= Heap_Words then
                     Base := Heap_Next;
                     Heap_Next := Heap_Next + Need;
                  else
                     --  Nothing free and no room to grow: a collection has
                     --  just run, so everything left is reachable.  This has
                     --  to stay a loud failure rather than a corruption.
                     Note ("heap exhausted");
                     return Bad_Code;
                  end if;
                  --  One word before the body holds the type tag, so a record
                  --  still has its first field at its own address + 0 and
                  --  nothing in the access paths has to know the tag exists.
                  --  The tag holds a biased reference, the form the walk
                  --  compares against, while `Ref` indexes TYPES directly.
                  Heap (Base) := U64 (Ref + 1);
                  for K in 1 .. Words loop
                     Heap (Base + K) := 0;
                  end loop;
                  Push (U64 (System.Storage_Elements.To_Integer
                               (Heap (Base + 1)'Address)));

               end;
               PC := PC + 5;
            when Op_Load_Fld_I | Op_Load_Fld_R | Op_Load_Fld_P =>
               --  A record is a run of scalar slots, so a field is the word at the
               --  record's address plus its offset.  The offset comes from the
               --  descriptor at compile time, so there is no runtime bound to check
               --  the way an array index has.
               declare
                  Off : constant Natural := LE16 (Code, PC + 1);
                  Rec : constant U64 := Pop;
                  V   : U64 with Address =>
                    System.Storage_Elements.To_Address
                      (System.Storage_Elements.Integer_Address (Rec)
                       + System.Storage_Elements.Integer_Address (Off));
               begin
                  Push (V);
               end;
               PC := PC + 3;
            when Op_Store_Fld_I | Op_Store_Fld_R | Op_Store_Fld_P =>
               declare
                  Val : constant U64 := Pop;
                  Off : constant Natural := LE16 (Code, PC + 1);
                  Rec : constant U64 := Pop;
                  V   : U64 with Address =>
                    System.Storage_Elements.To_Address
                      (System.Storage_Elements.Integer_Address (Rec)
                       + System.Storage_Elements.Integer_Address (Off));
               begin
                  V := Val;
               end;
               PC := PC + 3;
            when Op_Load_Const_R =>
               if PC + 4 >= Code'Length then
                  return Bad_Code;
               end if;
               --  Mirrors LOAD_CONST: the pool word is the real's 8-byte
               --  pattern, and the index is checked where that one's is.
               Push (LE64 (Consts, Natural (LE32 (Code, PC + 1)) * Const_Slot));
               PC := PC + 5;
            when Op_Radd | Op_Rsub | Op_Rmul | Op_Rdiv =>
               if SP < 2 then
                  return Bad_Stack;
               end if;
               declare
                  B : constant Long_Float := To_R64 (Pop);
                  A : constant Long_Float := To_R64 (Pop);
               begin
                  Push (R64_To_U64 (case Op is
                                       when Op_Radd => A + B,
                                       when Op_Rsub => A - B,
                                       when Op_Rmul => A * B,
                                       when others  => A / B));
               end;
               PC := PC + 1;
            when Op_Rneg | Op_Rabs =>
               if SP < 1 then
                  return Bad_Stack;
               end if;
               declare
                  A : constant Long_Float := To_R64 (Pop);
               begin
                  Push (R64_To_U64 (if Op = Op_Rneg then -A else abs A));
               end;
               PC := PC + 1;
            when Op_Req | Op_Rne | Op_Rlt | Op_Rle | Op_Rgt | Op_Rge =>
               if SP < 2 then
                  return Bad_Stack;
               end if;
               declare
                  B  : constant Long_Float := To_R64 (Pop);
                  A  : constant Long_Float := To_R64 (Pop);
                  R  : constant Boolean :=
                    (case Op is
                        when Op_Req => A = B,
                        when Op_Rne => A /= B,
                        when Op_Rlt => A < B,
                        when Op_Rle => A <= B,
                        when Op_Rgt => A > B,
                        when others => A >= B);
               begin
                  Push ((if R then U64 (1) else 0));
               end;
               PC := PC + 1;
            when Op_I2R =>
               if SP < 1 then
                  return Bad_Stack;
               end if;
               Push (R64_To_U64 (Long_Float (To_I64 (Pop))));
               PC := PC + 1;
            when Op_R2I_Round | Op_R2I_Trunc =>
               if SP < 1 then
                  return Bad_Stack;
               end if;
               declare
                  A : constant Long_Float := To_R64 (Pop);
                  V : Long_Float := A;
               begin
                  --  round to nearest, or truncate toward zero
                  if Op = Op_R2I_Round and then A >= 0.0 then
                     V := Long_Float (I64 (A + 0.5));
                  elsif Op = Op_R2I_Round then
                     V := Long_Float (I64 (A - 0.5));
                  else
                     V := Long_Float (I64 (A));
                  end if;
                  Push (To_U64 (I64 (V)));
               end;
               PC := PC + 1;
            when Op_Set_Union | Op_Set_Intersect | Op_Set_Diff
               | Op_Set_Symdiff =>
               if SP < 2 then
                  return Bad_Stack;
               end if;
               declare
                  B : constant U64 := Pop;
                  A : constant U64 := Pop;
               begin
                  Push (case Op is
                           when Op_Set_Union     => A or B,
                           when Op_Set_Intersect => A and B,
                           when Op_Set_Diff      => A and not B,
                           when others           => A xor B);
               end;
               PC := PC + 1;
            when Op_Set_Eq | Op_Set_Ne =>
               if SP < 2 then
                  return Bad_Stack;
               end if;
               declare
                  B : constant U64 := Pop;
                  A : constant U64 := Pop;
               begin
                  Push ((if (A = B) = (Op = Op_Set_Eq) then U64 (1) else 0));
               end;
               PC := PC + 1;
            when Op_Set_In =>
               if SP < 2 then
                  return Bad_Stack;
               end if;
               declare
                  S   : constant U64 := Pop;
                  Idx : constant U64 := Pop;
               begin
                  if Idx > 63 then
                     Note_At ("set element outside 0..63", PC);
                     return Trap_Range;
                  end if;
                  Push ((if (S / 2 ** Natural (Idx)) mod 2 = 1 then U64 (1)
                         else 0));
               end;
               PC := PC + 1;
            when Op_Set_Single =>
               if SP < 1 then
                  return Bad_Stack;
               end if;
               declare
                  Idx : constant U64 := Pop;
               begin
                  if Idx > 63 then
                     Note_At ("set element outside 0..63", PC);
                     return Trap_Range;
                  end if;
                  Push (2 ** Natural (Idx));
               end;
               PC := PC + 1;
            when Op_For_Enter =>
               --  u16 var slot, i32 step, u16 limit slot, u32 else target.
               --  from and to are on the operand stack, to on top; the
               --  named limit slot holds `to` and the direction follows it.
               if PC + 12 >= Code'Length then
                  return Bad_Code;
               end if;
               declare
                  Slot   : constant Natural :=
                    Natural (Code (PC + 1)) + Natural (Code (PC + 2)) * 256;
                  Limit  : constant Natural :=
                    Natural (Code (PC + 7)) + Natural (Code (PC + 8)) * 256;
                  Target : constant Natural := Natural (LE32 (Code, PC + 9));
                  Raw    : constant U64 := U64 (LE32 (Code, PC + 3));
                  Step   : constant I64 := (if Raw < 16#8000_0000#
                                            then To_I64 (Raw)
                                            else To_I64 (Raw - 16#1_0000_0000#));
                  From   : U64;
                  To     : U64;
                  Base   : Natural;
               begin
                  if Target > Code'Length then
                     return Bad_Target;
                  end if;
                  if Limit + 1 >= Frame_Slots (Cur_Frame) then
                     Note_At ("FOR slots out of range", PC);
                     return Bad_Stack;
                  end if;
                  Base := Frame_Base (Cur_Frame);
                  To := Pop;
                  From := Pop;
                  Locals (Base + Slot) := From;
                  Locals (Base + Limit) := To;
                  Locals (Base + Limit + 1) :=
                    (if From <= To then U64 (1) else U64 (0));
                  --  Oberon-2: the step's direction decides whether the body
                  --  runs at all, from the initial comparison.
                  if (Step >= 0 and then From > To)
                    or else (Step < 0 and then From < To)
                  then
                     PC := Target;
                  else
                     PC := PC + 11;
                  end if;
               end;
            when Op_For_Next =>
               --  u16 var slot, i32 step, u16 limit slot, u32 body target:
               --  step by the direction decided at entry, loop while in range.
               if PC + 12 >= Code'Length then
                  return Bad_Code;
               end if;
               declare
                  Slot   : constant Natural :=
                    Natural (Code (PC + 1)) + Natural (Code (PC + 2)) * 256;
                  Limit  : constant Natural :=
                    Natural (Code (PC + 7)) + Natural (Code (PC + 8)) * 256;
                  Target : constant Natural := Natural (LE32 (Code, PC + 9));
                  Raw    : constant U64 := U64 (LE32 (Code, PC + 3));
                  Step   : constant I64 := (if Raw < 16#8000_0000#
                                            then To_I64 (Raw)
                                            else To_I64 (Raw - 16#1_0000_0000#));
                  Base   : constant Natural := Frame_Base (Cur_Frame);
                  V      : I64;
                  Lim    : I64;
                  More   : Boolean;
               begin
                  if Target > Code'Length then
                     return Bad_Target;
                  end if;
                  if Limit + 1 >= Frame_Slots (Cur_Frame) then
                     Note_At ("FOR slots out of range", PC);
                     return Bad_Stack;
                  end if;
                  V := To_I64 (Locals (Base + Slot));
                  Lim := To_I64 (Locals (Base + Limit));
                  if Locals (Base + Limit + 1) = 1 then
                     V := V + abs (Step);
                  else
                     V := V - abs (Step);
                  end if;
                  Locals (Base + Slot) := To_U64 (V);
                  More := (if Locals (Base + Limit + 1) = 1 then V <= Lim
                           else V >= Lim);
                  if More then
                     PC := Target;
                  else
                     PC := PC + 13;
                  end if;
               end;
            when others =>
               Note_At ("opcode not implemented in this slice", PC);
               return Not_Implemented;
         end case;
      end loop;
   end Execute;

   --  Execute an image that is already in memory.  This is the same path
   --  Run uses, split out so a caller that *has* the bytes - notably o2c
   --  itself, which can run the image it just emitted - need not write
   --  them to a file first.
   function Run_Buffer (Data : Byte_Array) return Status is
      St    : Status;
      Img   : Image_Info;
      Phase : Natural := 0;
   begin
      Phase := 1;
      St := Decode (Data, Data'Length, Img);
      if St /= Ok then
         return St;
      end if;
      Phase := 2;
      St := Verify (Img.Code.all, Img);
      if St /= Ok then
         return St;
      end if;
      Phase := 3;
      return Execute (Data, Img);
   exception
      --  A malformed image must be *rejected*, never crash the VM: the
      --  spec's verification rules are checked, but a bug in the checks
      --  themselves must still surface as a status, not a CONSTRAINT_ERROR.
      when E : others =>
         Note ("internal error in phase" & Natural'Image (Phase) & ": "
               & Ada.Exceptions.Exception_Name (E)
               & " (" & Ada.Exceptions.Exception_Message (E) & ")");
         return Bad_Code;
   end Run_Buffer;

   function Run_Image (Image : String) return Status is
      B : constant Byte_Array_Access := new Byte_Array (0 .. Image'Length - 1);
   begin
      if Image'Length = 0 or else Image'Length > Max_File then
         return Bad_Size;
      end if;
      for I in Image'Range loop
         B (I - Image'First) := VM_IO.Byte (Character'Pos (Image (I)));
      end loop;
      return Run_Buffer (B.all);
   end Run_Image;

   function Run (Path : String) return Status is
      Data : constant Byte_Array_Access := new Byte_Array (0 .. Max_File - 1);
      Len  : Natural;
      St   : Status;
   begin
      declare
         Io_St : VM_IO.Status;
      begin
         VM_IO.Read_File (Path, Data.all, Len, Io_St);
         case Io_St is
            when VM_IO.Ok =>
               null;
            when VM_IO.Too_Big =>
               St := Bad_Size;
            when others =>
               St := Bad_File;
         end case;
      end;
      if St /= Ok then
         Note (Image (St) & ": " & Path);
         return St;
      end if;
      declare
         R : constant Status := Run_Buffer (Data (0 .. Len - 1));
      begin
         if R /= Ok then
            Note (Image (R) & ": " & Path);
         end if;
         return R;
      end;
   end Run;

end OBC_VM;
