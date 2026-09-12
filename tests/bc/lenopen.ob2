module Lenopen;
(*  LEN, which had NO bytecode emission at all.

    `i < len(name)` inside a procedure left the comparison a value short and the
    VM rejected the whole image as malformed ("CONSTRAINT_ERROR
    (obc_vm.adb:2129 range check failed)" - Top's Stack (SP - 1), an operand
    stack underflow).  The length lives in a different place depending on the
    array, which is the whole point of this test:

      - a GLOBAL array's length is its declared one (big is 8 even though it
        holds "abc"), so it is a constant at the use site;
      - an ARRAY OF parameter's length is the CALLER's, and travels in the
        parameter's second slot - so P(big) and P(small) must print DIFFERENT
        numbers from the same code.

    The last two lines are the ones that would pass by accident if the length
    were taken from the declaration rather than from the caller. *)
import Out;
type A8 = array 8 of char;
type A4 = array 4 of char;
var big: A8;
    small: A4;
procedure P (name: array of char);
begin
   Out.Int(len(name), 0); Out.Ln
end P;
begin
   big := "abc";
   small := "de";
   Out.Int(len(big), 0); Out.Ln;      (* 8: the declared length, not 3 *)
   Out.Int(len(small), 0); Out.Ln;    (* 4 *)
   P(big);                            (* 8: through an open parameter *)
   P(small)                           (* 4: the CALLER's length *)
end Lenopen.
