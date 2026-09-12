#  CALL_INDIRECT: calling through a procedure value.  The callee's id arrives
#  on the stack rather than in the instruction, because the callee is only
#  known at run time - which is what a PROCEDURE-typed variable holds.
MAXSTACK 4
GLOBALS 0
POOL cshow 2              # proc id of Show (1-based: main=1, Show=2)
POOL c1 1
POOL cw 0

ENTRY main
PROC main 0 0 0
  LOAD_CONST cshow
  CALL_INDIRECT
  HALT
PROC Show 0 0 0
  LOAD_CONST c1
  LOAD_CONST cw
  CALL_NATIVE 0 2
  CALL_NATIVE 2 0
  RET_VOID
