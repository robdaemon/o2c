#  A REAL record field, end to end: the oracle for LOAD_FLD_R/STORE_FLD_R.
#  A record is allocated, 0.5 goes into its offset-8 real field, and the value
#  is read back and printed through the REAL native.
MAXSTACK 8
GLOBALS 1
POOL_R half 0.5
POOL zero 0
DESC_REC rec 16

ENTRY main
PROC main 0 0 0
  ALLOC_NEW rec
  DUP                      # keep the record for the field read
  LOAD_CONST_R half
  STORE_FLD_R 8            # ptr.re := 0.5
  LOAD_FLD_R 8             # read ptr.re
  LOAD_CONST zero
  CALL_NATIVE 3 2          # Out.Real (v, 0)
  CALL_NATIVE 2 0
  HALT
