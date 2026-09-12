--  The Aegir interface o2c depends on, as code rather than as prose.
--
--  Every call o2c makes into Aegir is listed here and *referenced*, so that an
--  incompatible change on the Aegir side is a compile error in a file whose
--  only job is to fail.  Deliberately not a version pin: both repositories are
--  under development, and a pinned revision would be stale on arrival or force
--  the two into lockstep.  This is an interface check, evaluated against
--  whatever Aegir is now.
--
--  Why it exists: a comment in compat-aegir once asserted that the guest has
--  no environment.  That was false, nothing could check it, and it was found
--  only when a reader contradicted it.  A claim about another repository is
--  only worth anything when the compiler enforces it.
--
--  This catches drift in *what o2c calls*.  It cannot catch a claim o2c never
--  made in code - so the rule that goes with it is: use the API rather than
--  describe it.
package Aegir_Interface is

   --  Reference the whole surface once, at elaboration.  Taking 'Access has no
   --  side effect, so nothing here runs anything: it exists to make the
   --  compiler check every profile o2c relies on.
   procedure Touch;

end Aegir_Interface;
