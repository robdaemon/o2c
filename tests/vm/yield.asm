#  YIELD: a thread gives up the VM.  The instruction advances PC before
#  returning, so a scheduler resuming the context continues at the following
#  instruction rather than re-yielding forever.  No scheduler is wired yet, so
#  this checks the instruction itself and the status it reports.
MAXSTACK 4
GLOBALS 0
POOL c1 1
POOL cw 0

ENTRY main
PROC main 0 0 0
  YIELD
  LOAD_CONST c1
  LOAD_CONST cw
  CALL_NATIVE 0 2
  CALL_NATIVE 2 0
  HALT
