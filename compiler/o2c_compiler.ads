--  o2c M1 compiler core: parses the Oberon-2 subset (module,
--  import Out, const, nested procedures without parameters, a
--  statement sequence of calls) and emits a standalone Ada main
--  procedure that builds through the aegir program chain.
--
--  Keywords are case-insensitive (project deviation); identifiers
--  are case-sensitive per the Oberon-2 spec.
package O2c_Compiler is

   O2c_Error : exception;
   --  Raised (with a message) on the first syntax/semantic error.

   function Compile (Source : String) return String;
   --  Returns the generated Ada source for Source.

end O2c_Compiler;
