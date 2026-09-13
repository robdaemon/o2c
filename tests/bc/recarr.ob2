module Recarr;
(*  An array of multi-slot records: BY VALUE and through a POINTER.

    Both were broken once the record rule widened to accept the shape, and both
    were found by the read-only review (RESUME 3aj-3am):

      - Field_Offset placed a field by counting ONE SLOT PER FIELD, ignoring
        Total_Slots.  So `b` landed at byte 8 - inside a[0] - and writing it
        clobbered a[0].y: observed as `1 5 3 4 5`.  Fixed by extracting
        Field_Slots, which Total_Slots and Field_Offset now SHARE, so the two
        cannot disagree again;
      - the row-stride branch derived its base with Global_Array, which for a
        POINTER field is Total_Slots = 0, so `ptr^.a[i]` refused with "an array
        needs a non-zero length".  Measured incoming state settled it: a
        standalone array arrives base_ptr=FALSE/base_slots=8 with nothing on the
        stack, a pointer field arrives base_ptr=TRUE/base_slots=0.

    The array type must be NAMED - an inline `a: array 2 of T` field is refused
    with "a field type expected". *)
import Out;
type T = record x, y: integer end;
type A2T = array 2 of T;
type PRec = record a: A2T; b: integer end;
type PP = pointer to PRec;
var r: PRec; ptr: PP;
begin
   r.a[0].x := 1; r.a[0].y := 2;
   r.a[1].x := 3; r.a[1].y := 4;
   r.b := 5;
   Out.Int(r.a[0].x, 1); Out.Char(" ");
   Out.Int(r.a[0].y, 1); Out.Char(" ");
   Out.Int(r.a[1].x, 1); Out.Char(" ");
   Out.Int(r.a[1].y, 1); Out.Char(" ");
   Out.Int(r.b, 1); Out.Ln;
   new(ptr);
   ptr^.a[0].x := 6; ptr^.a[1].y := 7; ptr^.b := 8;
   Out.Int(ptr^.a[0].x, 1); Out.Char(" ");
   Out.Int(ptr^.a[1].y, 1); Out.Char(" ");
   Out.Int(ptr^.b, 1); Out.Ln
end Recarr.
