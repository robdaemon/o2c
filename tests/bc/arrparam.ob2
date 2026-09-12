module Arrparam;
(*  Out.String on an ARRAY OF parameter.

    This did not work at all: `Out.String (s)` inside a procedure failed with
    "bytecode emitter: operand-stack underflow" - a message about the STACK for
    a problem with a string, which is why it read as an emitter bug rather than
    as an unimplemented case.

    Two things were missing, and both are about where an open array's bytes
    are:

      - a bare ARRAY OF CHAR pushes NOTHING, because the parameter's own first
        slot holds the caller's address and nothing put it on the stack;
      - Out.String on a CHAR array is an inline print LOOP over a globals run,
        and an ARRAY OF parameter is not in the globals - its UT is 0, since an
        open array has no type of its own - so the loop was skipped and the
        pool-string native was used on an address.

    The pass-by-value case matters: P is called with two DIFFERENT arrays, so a
    loop that ran off a copy, or off the first caller's array, prints the wrong
    text rather than nothing. *)
import Out;
var a: array 8 of char;
    b: array 4 of char;
    c: array 16 of char;
procedure P (s: array of char);
begin
   Out.String(s); Out.Ln
end P;
begin
   a := "alpha";
   b := "beta";
   c := "gamma";
   P(a);      (* alpha *)
   P(b);      (* beta  - a shorter array, so a stale length shows here *)
   P(c);      (* gamma *)
   P(a)       (* alpha - and the first one again *)
end Arrparam.
