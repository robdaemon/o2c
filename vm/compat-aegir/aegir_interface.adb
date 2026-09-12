with Aegir_User.CLI;
with Aegir_User.Files;

package body Aegir_Interface is

   --  The result types o2c names, and the constants it compares against.
   --  Each of these fails to compile if the type behind the name changes.
   subtype Cli_Code  is Aegir_User.CLI.U64;
   subtype File_Code is Aegir_User.Files.U64;

   Cli_Ok   : constant Cli_Code  := Aegir_User.CLI.RC_Ok;
   Cli_Fail : constant Cli_Code  := Aegir_User.CLI.RC_Fail;
   File_Ok  : constant File_Code := Aegir_User.Files.Status_Ok;

   --  Signatures o2c calls through.  Named access types rather than a blanket
   --  one, so each declaration pins one profile: change a parameter on the
   --  Aegir side and the assignment below stops compiling.
   type Init_P    is access procedure;
   type Get_Env_P is access function (Name : String) return String;
   type Set_Env_P is access function (Name : String; Value : String)
     return Cli_Code;
   type Stat_P    is access function (Name : String; Size : out File_Code)
     return File_Code;
   type Del_P     is access function (Name : String) return File_Code;
   type Ren_P     is access function (From, To : String) return File_Code;

   Unused_Init : constant Init_P    := Aegir_User.CLI.Init'Access;
   Get_Env     : constant Get_Env_P := Aegir_User.CLI.Get_Env'Access;
   Set_Env     : constant Set_Env_P := Aegir_User.CLI.Set_Env'Access;
   Stat        : constant Stat_P    := Aegir_User.Files.Stat'Access;
   Delete      : constant Del_P     := Aegir_User.Files.Delete'Access;
   Rename      : constant Ren_P     := Aegir_User.Files.Rename'Access;
   pragma Unreferenced (Unused_Init, Get_Env, Set_Env, Stat, Delete, Rename);
   pragma Unreferenced (Cli_Ok, Cli_Fail, File_Ok);

   procedure Touch is
   begin
      --  Nothing runs.  The declarations above are the whole check, and they
      --  are evaluated by the compiler whether or not this is ever called.
      null;
   end Touch;

end Aegir_Interface;
