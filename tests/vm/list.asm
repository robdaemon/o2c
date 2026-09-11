#  A linked list, end to end: the oracle for LOAD_FLD_P/STORE_FLD_P.  Two
#  records are allocated, 42 goes into the first one's v field, the second is
#  linked to the first through its offset-8 pointer field, and 42 is read back
#  by following the link - p.next.v, three separate memory accesses.
MAXSTACK 8
GLOBALS 2
POOL v 42
POOL zero 0
DESC_REC rec 16

ENTRY main
PROC main 0 0 0
  ALLOC_NEW rec
  STORE_G 0                # p := NEW
  ALLOC_NEW rec
  STORE_G 1                # q := NEW
  LOAD_G 0
  LOAD_CONST v
  STORE_FLD_I 0            # p.v := 42
  LOAD_G 1
  LOAD_G 0
  STORE_FLD_P 8            # q.next := p
  LOAD_G 1
  LOAD_FLD_P 8             # q.next
  LOAD_FLD_I 0             # q.next.v
  LOAD_CONST zero
  CALL_NATIVE 0 2
  CALL_NATIVE 2 0
  HALT
