module Nobody;
(*  A module with NO statement part at all - declarations and `end Name.`

    This is legal Oberon and the builtin Files module is written that way, but
    the bytecode emitter assumed a body: Begin_Body was called only when a
    BEGIN was found, so Body_Proc stayed 0 and Encode indexed the procedure
    table at 0.  The symptom was a CONSTRAINT_ERROR inside the emitter on the
    real Files module - a crash, not a diagnostic, on a construct the language
    allows.

    Nothing is printed, so the golden is empty: what this asserts is that such
    a module COMPILES and RUNS, which is exactly what was not happening. *)
type Slot = record v: integer end;
var s: Slot;
end Nobody.
