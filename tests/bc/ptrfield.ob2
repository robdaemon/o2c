module Ptrfield;
(*  A field whose type is a NAMED pointer type, which was refused.

    There are two spellings for a pointer field and only one was recognised:

        next: Ptr      a field whose type names its OWN record (the linked-list
                       idiom).  Nothing names the pointer, so the field carries
                       the record's user type.
        p: Ptr         a field declared with a named pointer type - `p: Ptr`
                       where `type Ptr = pointer to Rec`.  This is what Files
                       uses (`f: File`), and it was not recognised as a leaf:
                       the walk fell through to "the view is a pointer" and
                       classified the whole designator as a bare pointer, which
                       the assignment path refuses by design.

    So `h.p := q` and `h.p^.n` were refused while `q^.next := p` worked - one
    construct, two spellings, one of them unusable.

    The values below pin the parts that are easy to get wrong.  Reading through
    the field (`h.p^.n`) must first LOAD the pointer off the stack, or the
    offset is applied to the OUTER record's address; that is a wrong number,
    not a refusal, so a golden is the only thing that can catch it.  And the
    pointer must survive the round trip through the field and out again. *)
import Out;
type Rec = record n: integer end;
type Ptr = pointer to Rec;
type Holder = record p: Ptr; tag: integer end;
var h: Holder; q: Ptr;
begin
   new(q);
   q^.n := 7;
   h.tag := 3;
   h.p := q;                        (* write a pointer INTO a field *)

   Out.Int(h.p^.n, 0); Out.Ln;      (* 7: read through the field *)
   Out.Int(h.tag, 0); Out.Ln;       (* 3: the field after it is undisturbed *)

   h.p := nil;                      (* NIL through a field *)
   if h.p = nil then Out.Int(1, 0) else Out.Int(0, 0) end; Out.Ln;   (* 1 *)

   new(q);                          (* and re-pointing it works *)
   q^.n := 9;
   h.p := q;
   Out.Int(h.p^.n, 0); Out.Ln       (* 9 *)
end Ptrfield.
