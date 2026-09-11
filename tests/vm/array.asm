#  Indexed access, end to end: the oracle for LOAD_ADDR_G/LOAD_IDX_I/
#  STORE_IDX_I.  Globals 0..3 stand in for a four-element array: store 42
#  into a[2] through its address, read it back and print it.
MAXSTACK 8
GLOBALS 4
POOL two 2
POOL zero 0
POOL v 42

ENTRY main
PROC main 0 0 0
  LOAD_ADDR_G 0
  LOAD_CONST two
  LOAD_CONST v
  STORE_IDX_I              # a[2] := 42
  LOAD_ADDR_G 0
  LOAD_CONST two
  LOAD_IDX_I               # read a[2]
  LOAD_CONST zero
  CALL_NATIVE 0 2
  CALL_NATIVE 2 0
  HALT
