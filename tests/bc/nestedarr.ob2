module Nestedarr;
(*  A two-level array, and two-level subscripting.

    `M2 = array 2 of V4` is the shape Files' own `Mat` has (docs/RESUME.md 3w in
    the compiler repo's notes).  It needed two things, each measured before
    either was committed:

      1a  an array whose ELEMENT is a user type is `Arr_Len * Total_Slots
          (Elem_UT)` slots, not `Arr_Len` - which made `array 2 of V4` claim two
          slots instead of eight;
      1b  a subscript on such an element selects a ROW, not a slot, so the row
          offset must be computed at the use site - no opcode scales by anything
          but one slot, the LOAD_IDX_* opcodes hard-code eight bytes - and the
          next subscript has to chain from THAT address.

    Without 1b the outer subscript was parsed and then dropped, so both rows
    aliased and this printed "10 11 12 13 10 11 12 13" instead of the line below.
    That is why it is a fixture and not a note. *)
import Out;
type V4 = array 4 of integer;
type M2 = array 2 of V4;
var m: M2; i, j: integer; first: boolean;
begin
   i := 0;
   while i < 2 do
      j := 0;
      while j < 4 do
         m[i][j] := i * 10 + j;
         j := j + 1
      end;
      i := i + 1
   end;
   first := True;
   i := 0;
   while i < 2 do
      j := 0;
      while j < 4 do
         if not first then Out.Char(" ") end;
         first := False;
         Out.Int(m[i][j], 1);
         j := j + 1
      end;
      i := i + 1
   end;
   Out.Ln
end Nestedarr.
