#  SPAWN starts a thread on a procedure.  main spawns Worker and halts; the
#  scheduler then gives Worker its turns, so its output appears even though
#  main is already out of turns.
MAXSTACK 4
GLOBALS 0
POOL cworker 2
POOL c2 2
POOL cw 0

ENTRY main
PROC main 0 0 0
  LOAD_CONST cworker
  SPAWN
  HALT
PROC Worker 0 0 0
  LOAD_CONST c2
  LOAD_CONST cw
  CALL_NATIVE 0 2
  CALL_NATIVE 2 0
  RET_VOID
