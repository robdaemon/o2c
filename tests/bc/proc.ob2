MODULE Proc;
IMPORT Out;

PROCEDURE Add(x: INTEGER; y: INTEGER);
BEGIN
  Out.Int(x + y, 0); Out.Ln
END Add;

BEGIN
  Add(40, 2)
END Proc.
