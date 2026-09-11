#  labs, end to end: the first foreign call.  -7 goes to native 5, the first
#  entry in the VM's foreign table, which is Ada's import of the C function.
#  The result is pushed - a native that produces a value, where every other
#  native so far only writes - and then printed with Out.Int(x, 0).
MAXSTACK 4
GLOBALS 0
POOL cn7 -7
POOL cw 0

ENTRY main
PROC main 0 0 0
  LOAD_CONST cn7
  CALL_NATIVE 5 1         # labs(-7), leaving 7 on the stack
  LOAD_CONST cw
  CALL_NATIVE 0 2         # Out.Int(7, 0)
  CALL_NATIVE 2 0         # Out.Ln
  HALT
