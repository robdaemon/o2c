#  A FOR loop, end to end: the oracle for FOR_ENTER_I/FOR_NEXT_I.  The loop
#  variable and its two hidden slots are slots 0, 1 and 2 of main's frame.
MAXSTACK 8
GLOBALS 1
POOL one 1
POOL five 5
POOL zero 0

ENTRY main
PROC main 3 0 0
  LOAD_CONST one
  LOAD_CONST five
  FOR_ENTER_I 0 1 1 L_else   # slot 0, step 1, limit slot 1, else target
L_top:
  LOAD_L 0
  LOAD_CONST zero
  CALL_NATIVE 0 2          # Out.Int (x, width)
  CALL_NATIVE 2 0          # Out.Ln
  FOR_NEXT_I 0 1 1 L_top
L_else:
  HALT
