module Longfield;
(*  A record with a LONGINT field, BY VALUE.

    `Files.Rider` is exactly this shape (`f: File; pos: longint; ...`), and it
    was refused because the field rule's list of whole-slot scalars omitted
    T_Long.  A POINTER to such a record does NOT exercise the rule - the check
    only runs for a variable whose type IS the record - and that is why an
    earlier probe of the same shape passed while the rule still refused:
    measured, `pos` reported typ=T_LONG scalar=FALSE. *)
import Out;
type A8 = array 8 of char;
type Rec = record name: A8; n: longint end;
var r: Rec;
begin
   r.name[0] := "z";
   r.n := 12345;
   if r.n = 12345 then Out.String("longint field ok")
   else Out.String("longint field WRONG") end;
   Out.Ln;
   r.n := -7;
   if r.n < 0 then Out.String("negative longint ok")
   else Out.String("negative longint WRONG") end;
   Out.Ln;
   Out.Char(r.name[0]); Out.Ln
end Longfield.
