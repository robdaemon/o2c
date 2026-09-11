#  A procedure call, end to end.  add(a, b) returns a + b; main passes 40 and
#  2 and prints the result, so the expected output is 42.
#
#  This is the VM's oracle for CALL/RET/LOAD_L: it is hand-assembled by
#  tools/obc_asm.py rather than emitted, so the interpreter is checked against
#  something that is not the emitter.  Note the argument order: the callee's
#  locals ARE its parameter slots, lowest slot first.
MAXSTACK 8
GLOBALS 0
POOL forty 40
POOL two 2
POOL zero 0

#  PROC name frame_slots nparams nresults
PROC add 2 2 1
  LOAD_L 0
  LOAD_L 1
  ADD
  RET

ENTRY main
PROC main 0 0 0
  LOAD_CONST forty
  LOAD_CONST two
  CALL add
  LOAD_CONST zero          # Out.Int takes (value, width)
  CALL_NATIVE 0 2          # Out.Int (x, width)
  CALL_NATIVE 2 0          # Out.Ln
  HALT
