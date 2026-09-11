#  REAL arithmetic, end to end: the oracle for 0x80-0x8B and LOAD_CONST_R.
#  Computes 1.5 + 2.5 and asks whether it equals 4.0 - expected output 1.
MAXSTACK 8
GLOBALS 0
POOL_R a 1.5
POOL_R b 2.5
POOL_R four 4.0
POOL zero 0

ENTRY main
PROC main 0 0 0
  LOAD_CONST_R a
  LOAD_CONST_R b
  RADD                     # 1.5 + 2.5 = 4.0
  LOAD_CONST_R four
  REQ                      # is it 4.0?
  LOAD_CONST zero
  CALL_NATIVE 0 2          # Out.Int (x, width)
  CALL_NATIVE 2 0
  HALT
