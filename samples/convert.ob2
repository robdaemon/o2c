module Convert;
procedure ConvToInt*(s: array of char; base: integer; var n: integer);
begin
  ConvToInt(s, base, n)
end ConvToInt;
procedure ConvToReal*(s: array of char; base: integer; var r: real);
begin
  ConvToReal(s, base, r)
end ConvToReal;
procedure ConvFromInt*(n: integer; var s: array of char);
begin
  ConvFromInt(n, s)
end ConvFromInt;
end Convert.
