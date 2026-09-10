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
   Max_Stack   : constant := 256;
   Max_Globals : constant := 4096;
   Max_Natives : constant := 3;

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

   function To_I64 is new Ada.Unchecked_Conversion (U64, I64);
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
     (2, 1, 0);

   --  ---- decoded image --------------------------------------------------
   type Image_Info is record
      Entry_Off   : Natural := 0;
      Body_Off    : Natural := 0;   --  code payload offset of the body
      Stack_Max   : Natural := 0;
      N_Globals   : Natural := 0;
      Globals_Off : Natural := 0;   --  offsets into the file
      Consts_Off  : Natural := 0;
      Consts_Len  : Natural := 0;
      Code_Off    : Natural := 0;
      Code_Len    : Natural := 0;
      --  The CODE and CONST payloads as 0-based heap copies, shared by the
      --  verifier and the interpreter (see the note in Decode).
      Code        : Byte_Array_Access := null;
      Consts_Copy : Byte_Array_Access := null;
   end record;

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

      declare
         Code : Byte_Array renames Img.Code.all;
         N_Procs : constant Natural := Natural (LE32 (Code, 0));
      begin
         if N_Procs /= 1 then
            --  the slice runs the module body only
            return Not_Implemented;
         end if;
         Img.Body_Off := 4 + Proc_Rec;
         --  record: code_off u32, frame_slots u32, nparams u16,
         --  nresults u16, stack_max u32, stackmap_off u32, line_ref u32
         --  so stack_max sits at record offset 12 == payload 4 + 12.
         Img.Stack_Max := Natural (LE32 (Code, 4 + 12));
         if Img.Entry_Off /= Img.Body_Off then
            return Bad_Target;
         end if;
         if Img.Stack_Max = 0 or else Img.Stack_Max > Max_Stack then
            return Bad_Size;
         end if;
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
                  return Bad_Code;
               end if;
               if Natural (Code (PC + 1)) > 5 then
                  return Bad_Code;
               end if;
               PC := PC + 2;
            when Op_Assert_Fail =>
               if not Fits (PC + 1, 4) then
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
                  return Bad_Code;
               end if;
               Depth := Depth + 1;
               PC := PC + 5;
            when Op_Store_G =>
               if not Fits (PC + 1, 4)
                 or else Natural (LE32 (Code, PC + 1)) >= Img.N_Globals
               then
                  return Bad_Code;
               end if;
               Depth := Depth - 1;
               PC := PC + 5;
            when Op_Load_Const =>
               if not Fits (PC + 1, 4) then
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
      Stack   : array (0 .. Max_Stack - 1) of U64 := (others => 0);
      Globals : array (0 .. Max_Globals - 1) of U64 := (others => 0);
      SP      : Natural := 0;
      PC      : Natural := Img.Body_Off;

      procedure Push (V : U64) is
      begin
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

      Op : Byte;
   begin
      --  module globals come from the DATA section (their initial values)
      for I in 0 .. Img.N_Globals - 1 loop
         Globals (I) := LE64 (Data, Img.Globals_Off + I * Const_Slot);
      end loop;

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
            when Op_Load_Const =>
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
            when others =>
               Note_At ("opcode not implemented in this slice", PC);
               return Not_Implemented;
         end case;
      end loop;
   end Execute;

   function Run (Path : String) return Status is
      Data : constant Byte_Array_Access := new Byte_Array (0 .. Max_File - 1);
      Len  : Natural;
      St   : Status;
      Img  : Image_Info;
      Phase : Natural := 0;
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
      Phase := 1;
      St := Decode (Data.all, Len, Img);
      if St /= Ok then
         Note (Image (St) & ": " & Path);
         return St;
      end if;
      Phase := 2;
      St := Verify (Img.Code.all, Img);
      if St /= Ok then
         Note (Image (St) & ": " & Path);
         return St;
      end if;
      Phase := 3;
      return Execute (Data.all, Img);
   exception
      --  A malformed image must be *rejected*, never crash the VM: the
      --  spec's verification rules are checked, but a bug in the checks
      --  themselves must still surface as a status, not a CONSTRAINT_ERROR.
      when E : others =>
         Note ("internal error in phase" & Natural'Image (Phase) & ": "
               & Ada.Exceptions.Exception_Name (E)
               & " (" & Ada.Exceptions.Exception_Message (E) & ")");
         return Bad_Code;
   end Run;

end OBC_VM;
