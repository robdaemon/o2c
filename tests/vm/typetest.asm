#  Type tests, end to end: the oracle for TYPE_TEST (and the tag word).
#  `child` extends `base`, so an object allocated as a child must test true
#  for base (walking the descriptor's base chain) and an object allocated as
#  base must test false for child.  Prints 1 then 0.
MAXSTACK 8
GLOBALS 0
POOL one 1
DESC_REC base 16
DESC_REC child 16 base

ENTRY main
PROC main 0 0 0
  ALLOC_NEW child
  TYPE_TEST base          # an ancestor of the dynamic type: true
  LOAD_CONST one
  CALL_NATIVE 0 2
  ALLOC_NEW base
  TYPE_TEST child         # base is not a child: false
  LOAD_CONST one
  CALL_NATIVE 0 2
  CALL_NATIVE 2 0
  HALT
