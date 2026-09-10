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
package O2c_BC is

   --  The opcodes this backend emits so far (names as in the spec table;
   --  `div`, `mod` and `abs` are Ada reserved words, hence the I-prefix).
   type Op is
     (Nop, Halt, Dup, Drop, Assert_Fail, Trap,
      Load_G, Store_G, Load_Const,
      Add, Sub, Mul, IDiv, IMod, Neg, IAbs,
      Eq, Ne, Lt, Le, Gt, Ge,
      Btest, Ord, Chr,
      Jmp, Jz, Jnz, Call_Native);

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

   --  ---- emission -------------------------------------------------------
   --  Each call appends one instruction and updates the stack model, so
   --  the emitted `stack_max` is a computed high-water mark, not a guess.
   procedure Push_Int (Value : Integer);
   procedure Push_Char (Value : Integer);
   procedure Push_Bool (Value : Boolean);
   --  A string constant: its pool word holds the string's offset inside
   --  the CONST payload, which is what Out.String consumes.
   procedure Push_Str (Text : String);
   procedure Load (Idx : Natural);
   procedure Store (Idx : Natural);
   procedure Bin (O : Op);
   procedure Un (O : Op);
   procedure Native_Call (Idx : Natural; NArgs : Natural);
   procedure Halt_Program;

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
