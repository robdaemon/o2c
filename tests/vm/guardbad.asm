#  GUARD's failure path: an object allocated as `base` guarded as `child`,
#  which it is not, so the guard must TRAP (kind 2) rather than yield a
#  pointer of the wrong type.
MAXSTACK 8
GLOBALS 0
DESC_REC base 16
DESC_REC child 16 base

ENTRY main
PROC main 0 0 0
  ALLOC_NEW base
  GUARD child
  HALT
