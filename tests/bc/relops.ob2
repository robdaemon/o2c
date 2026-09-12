module Relops;
(*  The six relations, so that no spelling goes unexercised.

    A corpus grep once reported "exactly two token kinds with no fixture",
    and `>=` was one of the two - recorded as working, but with nothing
    asserting it.  Here each relation is printed as 1 or 0 against a value
    where the answer is not the same as the neighbouring operator's, so a
    mis-emitted opcode cannot pass: `a >= b` and `a > b` differ on a = b,
    and `a <= b` and `a < b` differ there too. *)
import Out;
var a, b: integer; x, y: real; f: boolean;
begin
   a := 5; b := 7;
   f := a <  b;  if f then Out.Int(1, 0) else Out.Int(0, 0) end; Out.Ln;  (* 1 *)
   f := a <= b;  if f then Out.Int(1, 0) else Out.Int(0, 0) end; Out.Ln;  (* 1 *)
   f := a >  b;  if f then Out.Int(1, 0) else Out.Int(0, 0) end; Out.Ln;  (* 0 *)
   f := a >= b;  if f then Out.Int(1, 0) else Out.Int(0, 0) end; Out.Ln;  (* 0 *)
   f := b >= a;  if f then Out.Int(1, 0) else Out.Int(0, 0) end; Out.Ln;  (* 1 *)
   f := a =  b;  if f then Out.Int(1, 0) else Out.Int(0, 0) end; Out.Ln;  (* 0 *)
   f := a #  b;  if f then Out.Int(1, 0) else Out.Int(0, 0) end; Out.Ln;  (* 1 *)

   (* the boundary the four inequalities disagree about is equality *)
   b := 5;
   f := a >= b;  if f then Out.Int(1, 0) else Out.Int(0, 0) end; Out.Ln;  (* 1 *)
   f := a <= b;  if f then Out.Int(1, 0) else Out.Int(0, 0) end; Out.Ln;  (* 1 *)
   f := a >  b;  if f then Out.Int(1, 0) else Out.Int(0, 0) end; Out.Ln;  (* 0 *)
   f := a <  b;  if f then Out.Int(1, 0) else Out.Int(0, 0) end; Out.Ln;  (* 0 *)

   x := 2.5; y := 2.5;
   f := x >= y;  if f then Out.Int(1, 0) else Out.Int(0, 0) end; Out.Ln;  (* 1 *)
   f := x <= y;  if f then Out.Int(1, 0) else Out.Int(0, 0) end; Out.Ln;  (* 1 *)
   f := x >  y;  if f then Out.Int(1, 0) else Out.Int(0, 0) end; Out.Ln;  (* 0 *)

   x := 1.5;
   f := x >= y;  if f then Out.Int(1, 0) else Out.Int(0, 0) end; Out.Ln;  (* 0 *)
   f := x <  y;  if f then Out.Int(1, 0) else Out.Int(0, 0) end; Out.Ln   (* 1 *)
end Relops.
