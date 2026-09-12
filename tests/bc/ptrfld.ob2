module Ptrfld;
(*  Fields reached THROUGH A POINTER: an array field, and a LONGINT field.

    Both were refused, for unrelated reasons, and neither refusal named its
    real cause - which is why they lasted long enough for the only module
    that needed them (Files) to be written off as unportable.

      p^.name[i]   "an array needs a non-zero length".  The length was fine.
                   The index path took the GLOBALS route unconditionally,
                   and Total_Slots of a POINTER is zero.  The object's
                   address was already on the stack; the field's byte offset
                   had to be added to it, which is what the field path two
                   branches up already did.

      p^.size      "only INTEGER, CHAR, BOOLEAN, SET, REAL and LONGREAL
      (LONGINT)    record fields are supported".  LONGINT was simply missing
                   from that list - the same omission the assignment list had
                   already been fixed for, since a LONGINT is a 64-bit slot
                   exactly like an INTEGER.  A refusal by omission is
                   invisible when the message lists only what IS allowed.

    Every value below is read back out of the heap object, so a wrong offset
    (the array) or a wrong slot width (the LONGINT) shows up as a wrong number
    rather than as a refusal. *)
import Out;
type A8 = array 8 of char;
type Rec = record name: A8; size: longint; n: integer end;
(*  Named `Ptr` and not `P`: the Ada backend emits Oberon names verbatim, and
    Ada is case-insensitive, so `type P` beside `var p` is a collision there
    (see the recorded Ada-side limits in tests/differential.sh).  This fixture
    is about the VM's field addressing, so it avoids a known Ada-side
    limitation rather than being unable to corroborate anything. *)
type Ptr = pointer to Rec;
var p: Ptr; i: integer;
begin
   new(p);
   i := 0;
   while i < 3 do
      p^.name[i] := CHR(65 + i);      (* writes a BYTE per element *)
      i := i + 1
   end;
   p^.size := 5;                      (* a LONGINT field, 8 bytes *)
   p^.n := 9;

   Out.Char(p^.name[0]);              (* A: the array is at the object base *)
   Out.Char(p^.name[2]);              (* C: no stride mistake *)
   Out.Int(p^.n, 0);                  (* 9: the field AFTER both *)
   if p^.size = 5 then Out.Int(1, 0) else Out.Int(0, 0) end;   (* 1 *)
   Out.Ln
end Ptrfld.
