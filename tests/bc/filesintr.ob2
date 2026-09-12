module Files;
(*  The four positioned file intrinsics, by EFFECT.

    The module is named Files ON PURPOSE: the compiler gates FStat, FRead,
    FWrite and FClose on the module being `Files`, so a test of them has to be
    written as one.  That gate is also why nothing else in the corpus could
    reach them, and why the four could sit there emitting no opcode at all
    without any test noticing (see docs/bytecode-gaps.md A.2).

    Every assertion here is about the real filesystem: the size comes back from
    Stat, the byte read back is the byte written, and Close reports success.
    The scratch file is DELETED first so the first answer is deterministic
    rather than dependent on whether an earlier run left one behind - and
    deleted again at the end, so the fixture is hermetic.

    FDel and FRename are the other two intrinsics of the module; FDel is used
    here for the cleanup, which also exercises it. *)
import Out;
type A1 = array 1 of char;
var nm: array 40 of char;
    sz: longint;
    b: A1;
    res: integer;
begin
   nm := "/tmp/o2c_files_intr_scratch.txt";

   (* Start from nothing, so "absent" is a fact rather than an assumption. *)
   FDel(nm);
   sz := FStat(nm);
   if sz < 0 then Out.String("absent") else Out.String("ABSENT-BAD") end;
   Out.Ln;

   (* Write one byte at offset 0 - which also creates the file. *)
   b[0] := "Q";
   res := FWrite(nm, 0, b);
   Out.String("write="); Out.Int(res, 0); Out.Ln;

   (* ... and Stat now reports one byte, from the filesystem. *)
   sz := FStat(nm);
   if sz = 1 then Out.String("size=1") else Out.String("SIZE-BAD") end;
   Out.Ln;

   (* Read it back into a buffer that holds something else first: the read must
      REPLACE that byte, so 0Q is a real read and not a leftover. *)
   b[0] := "z";
   res := FRead(nm, 0, b);
   Out.String("read="); Out.Int(res, 0); Out.Char(b[0]); Out.Ln;

   res := FClose(nm);
   Out.String("close="); Out.Int(res, 0); Out.Ln;

   (* Leave nothing behind. *)
   FDel(nm)
end Files.
