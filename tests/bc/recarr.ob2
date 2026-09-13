module Recarr;
(*  An array of multi-slot records reached through a POINTER: `ptr^.a[i]`.

    The row-stride branch derived its base with Global_Array, which for a POINTER
    field is Total_Slots = 0, so this refused outright with "an array needs a
    non-zero length".  Fixed by deriving the base exactly as the scalar sibling
    does.  Measured incoming state, which is what settled it:

        standalone array: base_ptr=FALSE base_slots=8  nothing on the stack
        pointer field:    base_ptr=TRUE  base_slots=0  -> no Global_Array at all

    The BY-VALUE half of this shape is a separate, still-open finding: a record
    with an `a: A2T` field (A2T = array 2 of a two-slot record) still sizes A2T
    as two slots, so `b` aliases `a[0].y` - observed as `1 5 3 4 5` where the
    value should be `1 2 3 4 5`.  That reproduction is kept in RESUME 3am; it is
    deliberately NOT a fixture here, because a fixture that fails breaks run_bc. *)
import Out;
type T = record x, y: integer end;
type A2T = array 2 of T;
type PRec = record a: A2T; b: integer end;
type PP = pointer to PRec;
var ptr: PP;
begin
   new(ptr);
   ptr^.a[0].x := 6; ptr^.a[1].y := 7; ptr^.b := 8;
   Out.Int(ptr^.a[0].x, 1); Out.Char(" ");
   Out.Int(ptr^.a[1].y, 1); Out.Char(" ");
   Out.Int(ptr^.b, 1); Out.Ln
end Recarr.
