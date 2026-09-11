#  Record field access, end to end: the oracle for LOAD_FLD_I/STORE_FLD_I.
#  Two globals stand in for a two-field record; 42 goes into the field at
#  byte offset 8 and is read back, printing 42.
MAXSTACK 8
GLOBALS 2
POOL eight 8
POOL zero 0
POOL v 42

ENTRY main
PROC main 0 0 0
  LOAD_ADDR_G 0
  LOAD_CONST v
  STORE_FLD_I 8            # r.f := 42
  LOAD_ADDR_G 0
  LOAD_FLD_I 8             # read r.f
  LOAD_CONST zero
  CALL_NATIVE 0 2
  CALL_NATIVE 2 0
  HALT
