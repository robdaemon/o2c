--  The parent of the host console shim.
--
--  Ada needs this to exist at all: `with Aegir_User.Console;` in the emitted
--  code requires the parent unit Aegir_User to be a visible library unit, even
--  though the corpus never mentions it directly.  Without it every fixture
--  fails with `file "aegir_user.ads" not found` - and, being the first error,
--  it hides whatever the real problems are.
package Aegir_User is
end Aegir_User;
