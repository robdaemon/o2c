#  JOIN: main must not read what the thread wrote until the thread is done.
#  A value rather than an order, because the order depends on where the
#  scheduler happens to switch and a value does not.
MAXSTACK 4
GLOBALS 1
POOL cworker 2
POOL c7 7
POOL cw 0

ENTRY main
PROC main 0 0 0
  LOAD_CONST cw
  STORE_G 0
  LOAD_CONST cworker
  SPAWN
  JOIN
  LOAD_G 0
  LOAD_CONST cw
  CALL_NATIVE 0 2
  CALL_NATIVE 2 0
  HALT
PROC Worker 0 0 0
  LOAD_CONST c7
  STORE_G 0
  RET_VOID
