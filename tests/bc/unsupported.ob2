module Unsup;
import Out;
(* An inline (anonymous) array type, which the bytecode backend still
   cannot lay out.  This fixture used to assert that ARRAY OF CHAR was
   unsupported; CHAR arrays work now, so it moved to something that is
   still refused.  Kept as a fixture rather than deleted because the
   contract it checks is the general one: unsupported source fails
   loudly. *)
var v: array 4 of integer;
begin
  Out.Ln
end Unsup.
