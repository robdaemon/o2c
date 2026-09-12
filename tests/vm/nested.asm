#  A thread starting a thread: main spawns A, A spawns B and waits for it,
#  then reads what B wrote.  A value rather than an order, because the order
#  depends on where the scheduler happens to switch.
MAXSTACK 4
GLOBALS 1
POOL ca 2
POOL cb 3
POOL c5 5
POOL cw 0

ENTRY main
PROC main 0 0 0
  LOAD_CONST ca
  SPAWN
  DROP
  HALT
PROC A 0 0 0
  LOAD_CONST cw
  STORE_G 0
  LOAD_CONST cb
  SPAWN
  JOIN
  LOAD_G 0
  LOAD_CONST cw
  CALL_NATIVE 0 2
  CALL_NATIVE 2 0
  RET_VOID
PROC B 0 0 0
  LOAD_CONST c5
  STORE_G 0
  RET_VOID
