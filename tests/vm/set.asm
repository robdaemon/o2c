#  SET operations, end to end: the oracle for 0x3D-0x44.  Builds {1, 3} into
#  a global (SET_IN takes [idx, s], i.e. the index pushed first, so the set is
#  kept in a global rather than kept on the stack under the index), then
#  prints "2 IN s", "3 IN s", "s = {1,3}" and "{} = s" - expected output
#  0, 1, 1, 0, one per line.
MAXSTACK 8
GLOBALS 1
POOL zero 0
POOL one 1
POOL two 2
POOL three 3
POOL empty 0

ENTRY main
PROC main 0 0 0
  LOAD_CONST one
  SET_SINGLE               # {1}
  LOAD_CONST three
  SET_SINGLE               # {3}
  SET_UNION                # {1, 3}
  STORE_G 0

  LOAD_CONST two
  LOAD_G 0
  SET_IN                   # 2 IN s
  LOAD_CONST zero
  CALL_NATIVE 0 2          # Out.Int (x, width)
  CALL_NATIVE 2 0          # Out.Ln

  LOAD_CONST three
  LOAD_G 0
  SET_IN                   # 3 IN s
  LOAD_CONST zero
  CALL_NATIVE 0 2
  CALL_NATIVE 2 0

  LOAD_CONST one
  SET_SINGLE
  LOAD_CONST three
  SET_SINGLE
  SET_UNION                # {1, 3}
  LOAD_G 0
  SET_EQ                   # s = {1,3}
  LOAD_CONST zero
  CALL_NATIVE 0 2
  CALL_NATIVE 2 0

  LOAD_CONST empty
  LOAD_G 0
  SET_EQ                   # {} = s
  LOAD_CONST zero
  CALL_NATIVE 0 2
  CALL_NATIVE 2 0

  HALT
