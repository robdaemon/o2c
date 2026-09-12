module Unsup;
import Out;
(* Oberon-1 bounded-set syntax, which this dialect does not have: a SET
   here is unbounded and written plain.  This fixture asserts the general
   contract that unsupported source fails loudly.  It used to be an inline
   array type; inline arrays are supported now, so it moved to something
   that is still refused. *)
type S = set of 0 .. 7;
var v: S;
begin
  Out.Ln
end Unsup.
