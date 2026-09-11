MODULE Local;
IMPORT Out;

PROCEDURE Sum3(x: INTEGER);
VAR t: INTEGER;
BEGIN
  t := x + 1;
  Out.Int(t, 0); Out.Ln
END Sum3;

BEGIN
  Sum3(41)
END Local.
