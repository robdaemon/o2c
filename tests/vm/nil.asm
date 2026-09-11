#  Pointer constants, end to end: the oracle for LOAD_CONST_P.  A global is
#  set to NIL through a pool word of zero and compared against NIL, which
#  prints 1 (true).  No allocation: this is the half of pointers that does not
#  need the heap.
MAXSTACK 8
GLOBALS 1
POOL zero 0
POOL one 1

ENTRY main
PROC main 0 0 0
  LOAD_CONST_P zero        # NIL
  STORE_G 0                # p := NIL
  LOAD_G 0
  LOAD_CONST_P zero
  EQ                       # p = NIL
  LOAD_CONST one
  CALL_NATIVE 0 2
  CALL_NATIVE 2 0
  HALT
