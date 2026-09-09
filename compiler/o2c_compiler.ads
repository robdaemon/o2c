--  o2c M1 compiler core: parses the Oberon-2 subset (module,
--  import Out, const, nested procedures without parameters, a
--  statement sequence of calls) and emits a standalone Ada main
--  procedure that builds through the aegir program chain.
--
--  Keywords are case-insensitive (project deviation); identifiers
--  are case-sensitive per the Oberon-2 spec.
--
--  M19: modules compile from separate sources.  Compile_Multi takes
--  a command module plus library modules (in import order: any
--  module a library imports must be listed before it) and returns
--  one Ada source file per unit: each library becomes a package
--  (<name>.ads / <name>.adb), the command module the main
--  procedure (<name>.adb).  Library exports are marked 'name*';
--  importers use qualified M.name references.
with Ada.Strings.Unbounded;

package O2c_Compiler is

   O2c_Error : exception;
   --  Raised (with a message) on the first syntax/semantic error.

   function Compile (Source : String) return String;
   --  Returns the generated Ada source for the single command
   --  module Source (imports Out only).  M1 compatibility entry.

   Max_Libs : constant := 8;

   type Lib_Rec is record
      Name : Ada.Strings.Unbounded.Unbounded_String;  --  informational
      Text : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   type Lib_Array is array (1 .. Max_Libs) of Lib_Rec;

   Max_Units : constant := 24;

   type Unit_Rec is record
      File : Ada.Strings.Unbounded.Unbounded_String;
      Text : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   type Unit_Array is array (1 .. Max_Units) of Unit_Rec;

   function Compile_Multi (Main_Source : String; Libs : Lib_Array;
                           N_Libs : Natural; Count : out Natural)
                           return Unit_Array;
   --  Compiles Main_Source against the library modules Libs(1 ..
   --  N_Libs) and returns one Ada source per generated unit.  Count
   --  holds the number of units; units 1 .. Count of the result are
   --  valid.  Raises O2c_Error on the first error.

end O2c_Compiler;
