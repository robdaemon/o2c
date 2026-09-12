module StrCmp;
import Out;
type Line = array 8 of char;
var a: Line;
    b: Line;
    f: boolean;
begin
  a := "ab"; b := "ac";
  f := a = b; if f then Out.String("eq") else Out.String("ne") end; Out.Ln;
  f := a # b; if f then Out.String("ne") else Out.String("eq") end; Out.Ln;
  f := a < b; if f then Out.String("lt") else Out.String("ge") end; Out.Ln;
  f := a > b; if f then Out.String("gt") else Out.String("le") end; Out.Ln;
  a := "abc"; b := "ab";
  f := b < a; if f then Out.String("prefix-lt") else Out.String("x") end; Out.Ln;
  a := "same"; b := "same";
  f := a <= b; if f then Out.String("le") else Out.String("gt") end; Out.Ln
end StrCmp.
