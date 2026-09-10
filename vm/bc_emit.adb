--  Emitter self-test (M53): build, through O2c_BC, the very program
--  tests/vm/slice.asm hand-assembles - print a string, then sum 1..28 in
--  a WHILE loop - and write it as an image.
--
--  This proves the *encoder* end to end against the VM before the
--  front-end hooks land, which is the part of the backend most likely to
--  be wrong (offsets, pool layout, jump resolution).  Once the hooks
--  exist, the same golden output will come from real Oberon source and
--  this program stays as the encoder's regression test.
with Ada.Command_Line;
with Ada.Sequential_IO;
with Ada.Text_IO;
with O2c_BC;

procedure BC_Emit is
   package Char_IO is new Ada.Sequential_IO (Character);

   use type O2c_BC.Op;

   --  Interned after Begin_Mode: Begin_Mode resets the pools, so
   --  interning during elaboration would be wiped.
   Slot_I   : Natural;
   Slot_Sum : Natural;
   L_Top    : constant := 1;
   L_Done   : constant := 2;
begin
   if Ada.Command_Line.Argument_Count /= 1 then
      Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Error,
                            "usage: bc_emit <out.obc>");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      return;
   end if;

   O2c_BC.Begin_Mode;
   Slot_I := O2c_BC.Global ("i");
   Slot_Sum := O2c_BC.Global ("sum");

   --  Out.String ("vm slice ok"); Out.Ln
   O2c_BC.Push_Str ("vm slice ok");
   O2c_BC.Native_Call (1, 1);
   O2c_BC.Native_Call (2, 0);

   --  i := 1; sum := 0
   O2c_BC.Push_Int (1);
   O2c_BC.Store (Slot_I);
   O2c_BC.Push_Int (0);
   O2c_BC.Store (Slot_Sum);

   --  WHILE i <= 28 DO sum := sum + i; i := i + 1 END
   O2c_BC.Mark (L_Top);
   O2c_BC.Load (Slot_I);
   O2c_BC.Push_Int (28);
   O2c_BC.Bin (O2c_BC.Le);
   O2c_BC.Jump (O2c_BC.Jz, L_Done);
   O2c_BC.Load (Slot_Sum);
   O2c_BC.Load (Slot_I);
   O2c_BC.Bin (O2c_BC.Add);
   O2c_BC.Store (Slot_Sum);
   O2c_BC.Load (Slot_I);
   O2c_BC.Push_Int (1);
   O2c_BC.Bin (O2c_BC.Add);
   O2c_BC.Store (Slot_I);
   O2c_BC.Jump (O2c_BC.Jmp, L_Top);
   O2c_BC.Mark (L_Done);

   --  Out.Int (sum, 0); Out.Ln
   O2c_BC.Load (Slot_Sum);
   O2c_BC.Push_Int (0);
   O2c_BC.Native_Call (0, 2);
   O2c_BC.Native_Call (2, 0);
   O2c_BC.Halt_Program;

   declare
      Img : constant String := O2c_BC.Encode;
      F   : Char_IO.File_Type;
   begin
      Char_IO.Create (F, Char_IO.Out_File, Ada.Command_Line.Argument (1));
      for C of Img loop
         Char_IO.Write (F, C);
      end loop;
      Char_IO.Close (F);
      Ada.Text_IO.Put_Line ("bc_emit: " & Ada.Command_Line.Argument (1)
                            & " (" & Natural'Image (Img'Length)
                            & " bytes,"
                            & Natural'Image (O2c_BC.Global_Count)
                            & " globals,"
                            & Natural'Image (O2c_BC.Insns)
                            & " instructions)");
   end;
   O2c_BC.Finish;
end BC_Emit;
