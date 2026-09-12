#  A thread starting a thread.  main spawns A; A spawns B and prints 1; B
#  prints 2.  With a budget this large each runs to completion in turn, so
#  the order is fixed: 1 then 2.
MAXSTACK 4
GLOBALS 0
POOL ca 2
POOL cb 3
POOL c1 1
POOL c2 2
POOL cw 0

ENTRY main
PROC main 0 0 0
  LOAD_CONST ca
  SPAWN
  DROP
  HALT
PROC A 0 0 0
  LOAD_CONST cb
  SPAWN
  DROP
  LOAD_CONST c1
  LOAD_CONST cw
  CALL_NATIVE 0 2
  RET_VOID
PROC B 0 0 0
  LOAD_CONST c2
  LOAD_CONST cw
  CALL_NATIVE 0 2
  CALL_NATIVE 2 0
  RET_VOID
