--  o2c bytecode VM: image loader/verifier and stack interpreter.
--
--  Scope of this first slice (M53, "end-to-end thin slice"): the opcodes
--  needed by a module body that does INTEGER/CHAR/BOOLEAN work, assigns
--  module globals and calls Out.Int/Out.String/Out.Ln.  Everything else
--  in the v1 opcode table (docs/obc-image.md) is *defined* but reports
--  Not_Implemented, so a program using it fails loudly at load instead of
--  silently misbehaving.
--
--  Image-format offsets are relative to the start of the CODE section
--  payload; see docs/obc-image.md for the container and opcode tables.
package OBC_VM is
   type Status is
     (Ok,
      Bad_File,        --  unreadable, or not a regular file
      Bad_Magic,
      Bad_Version,
      Bad_Size,        --  header/section bounds, or a truncated section
      Bad_Section,     --  a mandatory section is missing
      Bad_Code,        --  malformed code payload or truncated instruction
      Bad_Target,      --  a jump/code offset outside the payload
      Bad_Stack,       --  operand-stack depth below zero or above stack_max
      Bad_Const,       --  a constant-pool reference outside the pool
      Bad_Native,      --  native index/arity outside the slice's table
      Not_Implemented, --  a defined v1 opcode this slice does not execute
      Trap_Index,      --  TRAP 0
      Trap_Nil,        --  TRAP 1
      Trap_Guard,      --  TRAP 2
      Trap_Divzero,    --  TRAP 3
      Trap_Range,      --  TRAP 5
      Assert_Failed,   --  ASSERT_FAIL
      Wants_More,      --  a native that would block, for the VM to park on
      Yielded);        --  the thread gave up the VM; resume it at PC

   --  Load, verify and interpret Path.  Returns Ok when the program ran to
   --  HALT, otherwise the first failure.  Diagnostics go to stderr.
   function Run (Path : String) return Status;

   --  Interpret an image already in memory (same verification and
   --  execution as Run).  o2c uses this to execute the bytecode it just
   --  emitted, in-process.
   function Run_Image (Image : String) return Status;

   --  Instructions a thread may run before the VM takes the machine back.
   --  Settable only so a test can drive it to 1, which forces a switch at
   --  every instruction boundary - where resumption bugs hide and where the
   --  default quantum never goes.  0 leaves it alone.
   procedure Set_Quantum (N : Natural);

   --  Human-readable status text, for the driver's exit diagnostic.
   function Image (S : Status) return String;

   --  The native id bound to a C symbol, or 0 when the VM does not know it.
   --  A stub module names the symbol it means, so the compiler asks here and
   --  a typo is a build error naming the symbol rather than a call to the
   --  wrong function.
   function Native_Id (Sym : String) return Natural;

   --  Whether that native produces a value.  The interpreter learns this
   --  from the native itself, but the emitter tracks operand-stack depth
   --  statically and has to know in advance, or a call that pushes reads as
   --  an imbalance and the next pop underflows.
   function Native_Pushes_At (Idx : Natural) return Boolean;
end OBC_VM;
