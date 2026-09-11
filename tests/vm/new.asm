#  Allocation, end to end: the oracle for ALLOC_NEW.  A TYPES descriptor
#  gives the object size; the object is allocated zeroed, 42 is stored into
#  the field at offset 8 through the pointer, and read back.
MAXSTACK 8
GLOBALS 1
POOL zero 0
POOL v 42
DESC_REC rec 16

ENTRY main
PROC main 0 0 0
  ALLOC_NEW rec            # -> [ptr]
  DUP                      # keep it for the field read
  LOAD_CONST v
  STORE_FLD_I 8            # ptr.f := 42
  LOAD_FLD_I 8             # read ptr.f
  LOAD_CONST zero
  CALL_NATIVE 0 2
  CALL_NATIVE 2 0
  HALT
