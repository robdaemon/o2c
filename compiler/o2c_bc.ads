--  Bytecode emission state for the o2c bytecode backend (M53).
--
--  The front end fills this package through *hooks* placed at the points
--  where it already applies an operator or stores a value, so the Ada
--  emitter stays the only text producer and this path is a parallel,
--  optional consumer of the same parse.  Every hook returns immediately
--  unless Bytecode_Mode is set, which is what keeps the Ada backend's
--  output byte-identical when bytecode mode is off.
--
--  Scope so far: the module body of a program whose body does INTEGER /
--  CHAR / BOOLEAN work on module-level scalars and calls Out.Int /
--  Out.String / Out.Ln.  Anything outside that raises a clear error
--  rather than emitting a wrong image; the caller uses Insns to detect
--  "this construct produced no code".
--
--  The image layout matches docs/obc-image.md and tools/obc_asm.py.
with Interfaces;

package O2c_BC is

   --  The opcodes this backend emits so far (names as in the spec table;
   --  `div`, `mod` and `abs` are Ada reserved words, hence the I-prefix).
   type Op is
     (Nop, Halt, Dup, Drop, Assert_Fail, Trap,
      Load_G, Store_G, Load_Const,
      Add, Sub, Mul, IDiv, IMod, Neg, IAbs,
      Eq, Ne, Lt, Le, Gt, Ge,
      Btest, Ord, Chr,
      Jmp, Jz, Jnz, Call_Native,
      --  Procedures and frames (M53 widening).  Appended, not inserted:
      --  the enum's order is fixed by the same append-only rule that fixes
      --  the byte numbers, and the byte numbers below are the spec's.
      Load_L, Store_L, Call, Ret, Ret_Void,
      Load_Addr_G, Load_Idx_I, Store_Idx_I,
      For_Enter_I, For_Next_I,
      Set_Union, Set_Intersect, Set_Diff, Set_Symdiff,
      Set_Eq, Set_Ne, Set_In, Set_Single,
      Radd, Rsub, Rmul, Rdiv, Rneg, Rabs,
      Req, Rne, Rlt, Rle, Rgt, Rge, I2R, R2I_Round, R2I_Trunc);

   --  ---- mode ------------------------------------------------------------
   --  True while the front end should feed this package.  Only the hook
   --  sites read it; the rest of the compiler ignores bytecode mode.
   Bytecode_Mode : Boolean := False;

   --  Start a fresh program: clears code, constants, globals and depth.
   procedure Begin_Mode;
   --  Discard the program state (leaves bytecode mode to the caller).
   procedure Finish;

   --  ---- program parts --------------------------------------------------
   --  Intern a module-level scalar, keyed by the name the front end uses
   --  for it, and return its slot in the image's globals block.  Globals
   --  are zero-initialised: the slice requires explicit initialisation in
   --  the body (documented limitation), so module-declaration
   --  initialisers are not yet carried into the image.
   function Global (Ada_Name : String) return Natural;
   function Global_Count return Natural;
   --  Intern a module-level array: it occupies a run of scalar slots, one per
   --  element, and the result is the slot of its first element.  The name is
   --  recorded so a later lookup finds it.
   function Global_Array (Ada_Name : String; Elements : Natural)
                          return Natural;

   --  ---- emission -------------------------------------------------------
   --  Each call appends one instruction and updates the stack model, so
   --  the emitted `stack_max` is a computed high-water mark, not a guess.
   procedure Push_Int (Value : Integer);
   --  A 64-bit constant.  SET masks are 64 bits and an element index may be
   --  above 31, so Push_Int is not enough.
   procedure Push_Word (Value : Interfaces.Unsigned_64);
   --  A REAL literal: its 8-byte pattern goes in the pool and is loaded with
   --  LOAD_CONST_R (0x2D), not LOAD_CONST.
   procedure Push_Real (Value : Long_Float);
   procedure Push_Char (Value : Integer);
   procedure Push_Bool (Value : Boolean);
   --  A string constant: its pool word holds the string's offset inside
   --  the CONST payload, which is what Out.String consumes.
   procedure Push_Str (Text : String);
   procedure Load (Idx : Natural);
   --  Push the address of a global slot.  An array is a run of slots, so
   --  this plus an index is how an element is reached.
   procedure Load_Addr_G (Slot : Natural);
   procedure Store (Idx : Natural);
   procedure Bin (O : Op);
   --  TRAP with its kind byte (spec: 0 = index out of range).  The VM reads
   --  the kind, so a bare Un (Trap) would desynchronise it.
   procedure Trap (Kind : Natural);
   procedure Un (O : Op);
   procedure Native_Call (Idx : Natural; NArgs : Natural);
   procedure Halt_Program;

   --  ---- procedures and frames ------------------------------------------
   --  A module's declared procedures are separate procedures in the CODE
   --  section, numbered in emission order; the module body is the final
   --  one and the image header's `entry` points at it.  Code offsets (a
   --  procedure's `code_off`, CALL's operand and every jump target) are
   --  relative to the start of the CODE section payload, which is what the
   --  VM verifies and resolves against.
   function Begin_Proc (NParams : Natural; NResults : Natural) return Natural;
   procedure End_Proc;
   --  Open the module body.  Called when the statement part begins, after
   --  every declared procedure has been closed, so the body's code is
   --  contiguous and last.
   procedure Begin_Body;

   --  Frame local of the currently open procedure: interned by name and
   --  numbered from 0, so the frame slots are the parameter slots.
   function Local (Ada_Name : String) return Natural;
   function Local_Count return Natural;
   --  Look up a frame local of the currently open procedure WITHOUT
   --  interning one: -1 means "no such local", so a use site can fall back
   --  to a module global instead of silently minting a fresh frame slot for
   --  a name that was never declared as a local.
   function Local_Slot (Ada_Name : String) return Integer;
   --  True while a procedure is open.  The front end may reach a procedure
   --  declaration more than once for one declaration, and Begin_Proc must
   --  run once: this is how it tells.
   function Proc_Open return Boolean;

   --  Stack shuffles with their real depth effects.  Un() is for unary
   --  value operators (NEG, ABS, ORD, CHR), which leave the depth alone;
   --  DUP pushes and DROP pops, so emitting them through Un() would make
   --  the computed stack_max and the underflow checks wrong.
   procedure Dup_Top;
   procedure Discard;

   procedure Load_Local (Slot : Natural);
   procedure Store_Local (Slot : Natural);
   procedure Call_Proc (Proc_Id : Natural);
   procedure Return_Value;
   procedure Return_Void;

   --  FOR loops.  The variable's slot is followed by two hidden frame slots,
   --  limit then direction - the convention the VM reads, and why a FOR
   --  inside a procedure grows frame_slots by three.  from and to are on
   --  the operand stack when FOR_ENTER runs, to on top.
   procedure For_Enter (Slot : Natural; Step : Integer; Else_Label : Natural);
   procedure For_Next (Slot : Natural; Step : Integer; Limit_Slot : Natural;
                       Body_Label : Natural);

   --  Byte offset of the next instruction in the code buffer: a procedure
   --  captures this when its code starts.
   function Code_Offset return Natural;

   --  ---- labels ---------------------------------------------------------
   --  A label is an opaque number the caller allocates per construct.
   procedure Mark (Label_Id : Natural);
   procedure Jump (O : Op; Label_Id : Natural);

   --  Instruction count: only ever grows, so a caller can tell whether a
   --  construct emitted any code at all.
   function Insns return Natural;

   --  Raised by Encode if a jump was never resolved, and by the front end
   --  when bytecode mode meets a construct this backend cannot express.
   Wrong_Construct : exception;

   --  ---- image ----------------------------------------------------------
   function Encode return String;

end O2c_BC;
