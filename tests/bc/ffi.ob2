module Ffi;
import Out;
var y: integer;
(* A foreign declaration: no Oberon body, bound to a C function.  The name
   deliberately avoids Abs/Max/Min/Ord/Chr/Len, which are builtins and are
   intercepted before symbol resolution - a stub naming one of those binds
   nothing and silently emits no call. *)
procedure LabsOf (x: integer): integer EXTERN "labs";
END LabsOf;
begin
  y := LabsOf(0 - 7);
  Out.Int(y, 0);
  Out.Ln
end Ffi.
