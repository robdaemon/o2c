#  Out.Char, end to end: the oracle for native 4.  A character code goes to
#  the native, which prints the character itself.
MAXSTACK 4
GLOBALS 0
POOL ca 65                # 'A'
POOL cb 66                # 'B'

ENTRY main
PROC main 0 0 0
  LOAD_CONST ca
  CALL_NATIVE 4 1         # Out.Char('A')
  LOAD_CONST cb
  CALL_NATIVE 4 1         # Out.Char('B')
  CALL_NATIVE 2 0
  HALT
