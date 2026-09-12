#  JOIN waits for a thread.  main prints 1, spawns Worker, prints nothing more
#  until Worker is done.  Without the join parking main, main would print 3
#  before Worker printed 2 - so the order of the output is the test.
MAXSTACK 4
GLOBALS 0
POOL cworker 2
POOL c1 1
POOL c2 2
POOL c3 3
POOL cw 0

ENTRY main
PROC main 0 0 0
  LOAD_CONST cworker
  SPAWN                     # leaves Worker's handle
  LOAD_CONST c1
  LOAD_CONST cw
  CALL_NATIVE 0 2           # print 1
  CALL_NATIVE 2 0           # newline
  JOIN                      # wait for Worker
  LOAD_CONST c3
  LOAD_CONST cw
  CALL_NATIVE 0 2           # print 3, after Worker's 2
  CALL_NATIVE 2 0
  HALT
PROC Worker 0 0 0
  LOAD_CONST c2
  LOAD_CONST cw
  CALL_NATIVE 0 2           # print 2
  CALL_NATIVE 2 0
  RET_VOID
