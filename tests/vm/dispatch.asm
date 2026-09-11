#  Dynamic dispatch, end to end: the oracle for DISPATCH.  `base` has method 0
#  and method 1; `child` (an extension) inherits both and overrides method 0.
#  Dispatching method 0 on a child must reach the child's implementation and
#  method 1 the inherited one - that is the whole point of a method table, and
#  the second call is what proves the table is copied rather than searched.
MAXSTACK 8
GLOBALS 1
POOL zero 0
POOL one 1
METHODS base_m base_m0 base_m1
METHODS child_m child_m0 base_m1
DESC_REC base 16 - base_m
DESC_REC child 16 base child_m

ENTRY main
PROC main 0 0 0
  ALLOC_NEW child
  DISPATCH 0 0 1           # method 0 on a child: the override
  LOAD_CONST one
  CALL_NATIVE 0 2
  ALLOC_NEW child
  DISPATCH 1 0 1           # method 1: inherited from base
  LOAD_CONST one
  CALL_NATIVE 0 2
  CALL_NATIVE 2 0
  HALT
PROC base_m0 1 1 1
  LOAD_CONST zero
  RET
PROC child_m0 1 1 1
  LOAD_CONST one
  RET
PROC base_m1 1 1 1
  LOAD_CONST zero
  RET
