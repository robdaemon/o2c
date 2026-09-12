#  main holds the lock and then waits for Worker, which can only wait for the
#  lock.  With mutual exclusion nothing is runnable, and that is a deadlock -
#  which is how the lock blocking is observed.  A lock that did not block
#  would let Worker run, and the program would print 21 and exit cleanly.
MAXSTACK 4
GLOBALS 1
POOL cworker 2
POOL c1 1
POOL c2 2
POOL cw 0

ENTRY main
PROC main 0 0 0
  MUTEX_LOCK 0
  LOAD_CONST cworker
  SPAWN
  JOIN
  MUTEX_UNLOCK 0
  LOAD_CONST c1
  LOAD_CONST cw
  CALL_NATIVE 0 2
  CALL_NATIVE 2 0
  HALT
PROC Worker 0 0 0
  MUTEX_LOCK 0
  MUTEX_UNLOCK 0
  LOAD_CONST c2
  LOAD_CONST cw
  CALL_NATIVE 0 2
  CALL_NATIVE 2 0
  RET_VOID
