module Gcscalar;
import Out;
type Cell = record a: integer; b: integer end;
type P = pointer to Cell;
var p: P; i, sum: integer;
begin
  (* Every field is a scalar, so this descriptor has has_ptrs clear and the
     mark must not scan the body: reading a value as a pointer would follow
     it into nonsense.  Only one Cell is live at a time, so 20000 allocations
     through a 64 KiB arena exercise reclamation on a pointer-free type. *)
  sum := 0;
  for i := 1 to 20000 do
    NEW(p);
    p^.a := i;
    p^.b := i * 2;
    sum := sum + p^.a + p^.b
  end;
  Out.Int(sum, 0);
  Out.Ln
end Gcscalar.
