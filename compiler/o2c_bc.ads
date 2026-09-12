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
      Load_Addr_G, Load_Idx_I, Store_Idx_I, Load_Fld_I, Store_Fld_I, Load_Fld_R, Store_Fld_R,
      Load_Fld_P, Store_Fld_P, Load_Const_P,
      For_Enter_I, For_Next_I,
      Set_Union, Set_Intersect, Set_Diff, Set_Symdiff,
      Set_Eq, Set_Ne, Set_In, Set_Single,
      Radd, Rsub, Rmul, Rdiv, Rneg, Rabs,
      Req, Rne, Rlt, Rle, Rgt, Rge, I2R, R2I_Round, R2I_Trunc,
      --  Calling through a procedure value.  Appended for the same reason
      --  everything else here is: the enum's order is fixed.
      Call_Indirect);

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
   --  Record field access by pre-validated byte offset within the record
   --  (spec 0x23/0x26): no runtime bound to check, the emitter knows the
   --  layout.
   procedure Load_Fld (Off : Natural);
   --  The same access for a field that holds a pointer.  A pointer is an
   --  8-byte word like an integer, so only the opcode differs; what it buys
   --  is that a reader can tell a pointer field from an integer one.
   procedure Load_Fld_P (Off : Natural);
   --  And for a REAL or LONGREAL field.  Another 8-byte word, so again only
   --  the opcode differs; it is what marks the field as a real to a reader.
   procedure Load_Fld_R (Off : Natural);
   procedure Store_Fld_R (Off : Natural);
   procedure Store_Fld_P (Off : Natural);
   procedure Drop;
   --  NIL: a pointer constant.  The pool word is zero, so the opcode differs
   --  from LOAD_CONST only in what a reader can conclude about it.
   procedure Push_Nil;
   --  A RECORD type descriptor for TYPES.  The result is a *reference* to
   --  it - the byte offset plus one - which is the form ALLOC_NEW, GUARD,
   --  TYPE_TEST and a descriptor's `base` all use, so that zero can mean
   --  none while the outermost descriptor still sits at offset zero.  Layout is
   --  declaration order, one scalar slot per field, so the size is N_F * 8.
   function Desc_Rec (Size : Natural; Base : Natural; Methods : Natural;
                      Has_Ptrs : Boolean) return Natural;
   --  TYPE_TEST: leaves whether the pointer on top has that dynamic type,
   --  or an extension of it.
   procedure Type_Test (Ref : Natural);
   --  GUARD: leaves the pointer if its dynamic type is that one or an
   --  extension, and traps (kind 2) if not.  NIL passes.
   procedure Guard (Ref : Natural);
   --  A method table: `n` u32 followed by n procedure ids.  The result is the
   --  reference a descriptor's methods field holds.  A type's table is its
   --  parent's followed by its own, so an override keeps its base's slot.
   type Id_List is array (Natural range <>) of Natural;
   function Method_Table (Ids : Id_List) return Natural;
   --  DISPATCH through the receiver on the stack, under its arguments.
   --  Both counts are static; the callee is not.
   procedure Dispatch (Method_Idx : Natural; Arg_Count : Natural;
                       Result_Count : Natural);
   --  Allocate a zeroed object of the descriptor's size and push its address.
   procedure Alloc_New (Desc_Ref : Natural);
   procedure Store_Fld (Off : Natural);
   procedure Un (O : Op);
   procedure Native_Call (Idx : Natural; NArgs : Natural);
   --  Call the procedure whose id is on top of the stack, consuming it.  The
   --  callee is only known at run time - which is what a PROCEDURE-typed
   --  value holds - and the type guarantees it takes no arguments and
   --  returns no result.
   procedure Call_Indirect;
   --  Start a thread on the procedure id on top of the stack, consuming it.
   --  The entry point is a procedure value, so it may come from a variable.
   procedure Spawn;
   --  Wait for the thread whose handle is on top of the stack, consuming it.
   --  Parks the calling thread rather than spinning.
   procedure Join;
   --  Give up the rest of this thread's quantum voluntarily.  The same
   --  mechanism preemption uses, asked for instead of forced - which is why
   --  it needs no state and no operand.
   procedure Thread_Yield;
   --  Push the calling thread's own id.
   procedure Thread_Id;
   --  Lock and unlock a mutex named by its globals slot.  A mutex is an
   --  INTEGER the program owns, so nothing here needs a handle or a table.
   procedure Mutex_Lock (Slot : Natural);
   procedure Mutex_Unlock (Slot : Natural);

   --  Push a procedure id: what a PROCEDURE-typed value is.  One slot, and
   --  the VM already numbers procedures, so a procedure value needs no
   --  environment and nothing from the collector.
   procedure Push_BC_Proc (Proc_Id : Natural);
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
   procedure For_Enter (Slot : Natural; Step : Integer; Limit_Slot : Natural;
                        Else_Label : Natural);
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

   --  The native id bound to a C symbol, or 0 when the VM does not know it.
   --  The compiler asks the emitter rather than the VM directly: O2c_BC is
   --  already its view of the bytecode world, and the VM dependency belongs
   --  on this side of that line rather than as a second path to it.
   function Foreign_Id (Sym : String) return Natural;

   --  Whether native Idx leaves a result on the stack, so Native_Call can
   --  track depth correctly.  The builtins are all void; foreign functions
   --  usually are not.
   function Foreign_Pushes (Idx : Natural) return Boolean;

   --  Raised by Encode if a jump was never resolved, and by the front end
   --  when bytecode mode meets a construct this backend cannot express.
   Wrong_Construct : exception;

   --  ---- image ----------------------------------------------------------
   function Encode return String;

end O2c_BC;
