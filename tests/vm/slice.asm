# thin-slice test: print a string, then sum 1..28 (406) in a WHILE loop
globals 2
maxstack 8
POOL c0 0
POOL c1 1
POOL c28 28
STR  strmsg "vm slice ok"
ENTRY main
main:
  LOAD_CONST strmsg
  CALL_NATIVE 1 1
  CALL_NATIVE 2 0
  LOAD_CONST c1
  STORE_G 0
  LOAD_CONST c0
  STORE_G 1
loop:
  LOAD_G 0
  LOAD_CONST c28
  LE
  JZ done
  LOAD_G 1
  LOAD_G 0
  ADD
  STORE_G 1
  LOAD_G 0
  LOAD_CONST c1
  ADD
  STORE_G 0
  JMP loop
done:
  LOAD_G 1
  LOAD_CONST c0
  CALL_NATIVE 0 2
  CALL_NATIVE 2 0
  HALT
