module Hello;
import Out, Geom, Geo, Math, MathL, Strings, Texts, Files, In,
       Input, Reals, Term, XYplane, Args, Err, Env;

type Vector = array 4 of integer;
type Pair = record a, b: integer end;
type Line = array 8 of char;
type FLine = array 64 of char;
type Node = pointer to NodeDesc;
type NodeDesc = record v: integer; next: Node end;
type Shape = record x: integer end;
type Circle = record (Shape) r: integer end;
type PShape = pointer to Shape;
type PCircle = pointer to Circle;
type P3 = record (Geom.Point) z: integer end;
type Mat = array 2 of Vector;
type Tote = record m: Mat; k: integer end;

var n: integer;
var v: Vector; p: Pair; q: Pair; i: integer;
var msg: Line; ch: char;
var head, cur: Node;
var shp: PShape; circ: PCircle;
var sac: Tote;
var s2: set; l2: longint;
var r: real;
var lre: longreal;
var m: integer;
var a, b: Geom.Point;
var tw: Texts.Writer;
var rg: Geo.Rect;
var bx: Geo.Box;
var hx, tx: Geom.Node;
var w: Geom.Vec;
var px: P3;
var fd: Files.File; rr: Files.Rider; fl: FLine; cc: char; fi: integer;

const Greeting = "hello from Oberon-2";

procedure CountTo(k: integer; var total: integer);
begin
  total := 0;
  while total < k * 2 do
    total := total + 1
  end;
  if total = k * 2 then
    Out.Int(total, 0);
    Out.Ln
  else
    Out.Int(0, 0);
    Out.Ln
  end
end CountTo;

procedure Square(x: integer): integer;
begin
  return x * x
end Square;

procedure UpTo12;
  const Goal = 12;
  var k: integer;
begin
  k := 9;
  loop
    k := k + 1;
    if k = Goal then exit end
  end;
  Out.Int(k, 0);
  Out.Ln
end UpTo12;

procedure Dot;
  type Pt = pointer to Point;
  type Point = record x, y: integer end;
  var q: Pt; d: integer;
begin
  new(q);
  q^.x := 3;
  q^.y := 4;
  d := q^.x + q^.y;
  Out.Int(d, 0);
  Out.Ln
end Dot;

procedure Push(var l: Node; v: integer);
  var n: Node;
begin
  new(n);
  n^.v := v;
  n^.next := l;
  l := n
end Push;

procedure SwapPair(var r: Pair);
  var t: integer;
begin
  t := r.a;
  r.a := r.b;
  r.b := t
end SwapPair;

procedure Last(l: Node): Node;
  var r: Node;
begin
  r := l;
  if r # nil then
    while r^.next # nil do
      r := r^.next
    end
  end;
  return r
end Last;

procedure Sum(l: Node): integer;
  var r: Node; t: integer;
begin
  r := l;
  t := 0;
  while r # nil do
    t := t + r^.v;
    r := r^.next
  end;
  return t
end Sum;

procedure FillArr(var a: array of integer; start: integer);
  var j: integer;
begin
  for j := 0 to len(a) - 1 do
    a[j] := start + j
  end
end FillArr;

procedure SumArr(a: array of integer): integer;
  var j, t: integer;
begin
  t := 0;
  for j := 0 to len(a) - 1 do
    t := t + a[j]
  end;
  return t
end SumArr;

procedure CLen(s: array of char): integer;
begin
  return len(s)
end CLen;

procedure (var s: Shape) Widen (k: integer);
begin
  s.x := s.x + k
end Widen;

procedure (var c: Circle) Widen (k: integer);
begin
  c.r := c.r + k
end Widen;

procedure (var c: Circle) Ring: integer;
begin
  return c.r
end Ring;


procedure (var q: P3) AddZ(d: integer);
begin
  q.z := q.z + d
end AddZ;
begin
  n := 0;
  repeat
    n := n + 1;
    Out.Int(n, 0)
  until n = 3;
  Out.Ln;
  Out.String(Greeting);
  Out.Ln;
  for n := 4 to 5 do
    Out.Int(n, 0)
  end;
  Out.Ln;

  Out.Int(Square(3), 0);
  Out.Ln;
  i := 0;
  while i < 4 do
    v[i] := i * i;
    i := i + 1
  end;
  i := 0;
  repeat
    Out.Int(v[i], 0);
    i := i + 1
  until i = 4;
  Out.Ln;
  p.a := 7;
  p.b := Square(p.a) - 1;
  Out.Int(p.b, 0);
  Out.Ln;
  q := p;
  Out.Int(q.b, 0);
  Out.Ln;
  SwapPair(p);
  Out.Int(p.a, 0);
  Out.Ln;
  Out.Int(p.b, 0);
  Out.Ln;
  msg := "hi";
  msg[0] := "H";
  Out.String(msg);
  Out.Ln;
  ch := msg[0];
  if ch = "H" then
    Out.Int(7, 0);
    Out.Ln
  end
  i := 2;
  case i of
    0: Out.Int(0, 0)
  | 1: Out.String("one")
  | 2, 3: Out.Int(i, 0)
  else
    Out.Int(9, 0)
  end;
  Out.Ln
  CountTo(21, n);
  head := nil;
  Push(head, 1);
  Push(head, 2);
  Push(head, 3);
  cur := Last(head);
  Out.Int(head^.v, 0);
  Out.Ln;
  Out.Int(cur^.v, 0);
  Out.Ln;
  Out.Int(Sum(head), 0);
  Out.Ln;
  FillArr(v, 5);
  Out.Int(SumArr(v), 0);
  Out.Ln;
  Out.Int(len(v), 0);
  Out.Ln;
  Out.Int(CLen(msg), 0);
  Out.Ln;
  UpTo12;
  Dot;
  new(shp);
  shp^.x := 0;
  new(circ);
  circ^.x := 10;
  circ^.r := 1;
  shp.Widen(7);
  Out.Int(shp^.x, 0);
  Out.Ln;
  circ.Widen(4);
  Out.Int(circ^.r, 0);
  Out.Ln;
  if circ IS Circle then
    with circ: Circle do
      circ^.r := circ^.r + 2
    end;
    Out.Int(circ^.r, 0);
    Out.Ln
  end;
  shp := circ;
  shp.Widen(3);
  Out.Int(circ.Ring(), 0);
  Out.Ln;
  sac.m[0][1] := 3;
  sac.m[1][2] := 4;
  sac.k := 5;
  Out.Int(sac.m[0][1] + sac.m[1][2] + sac.k, 0);
  Out.Ln;
  s2 := {2, 4, 6};
  if 4 IN s2 then Out.Int(4, 0); Out.Ln end;
  s2 := s2 - {6};
  if 6 IN s2 then Out.Int(0, 0) else Out.Int(6, 0) end;
  Out.Ln;
  l2 := 0;
  while l2 < 60 do
    l2 := l2 + 1
  end;
  if l2 = 60 then Out.Int(1, 0) else Out.Int(0, 0) end;
  Out.Ln;
  r := 6.25;
  r := r / 2.5;
  if r = 2.5 then Out.Real(r, 0) end;
  Out.Ln;
  m := Geom.Sqr(6);
  Out.Int(m, 0);
  Out.Ln;
  Geom.SetBase(7);
  m := 0;
  Geom.Bump(m);
  Geom.Bump(m);
  Out.Int(m, 0);
  Out.Ln;
  Geom.count := m + 1;
  Out.Int(Geom.count, 0);
  Out.Ln;
  Out.Real(Geom.Pi, 0);
  Out.Ln;
  a.x := 60;
  a.y := 40;
  b := a;
  Out.Int(a.x + b.y, 0);
  Out.Ln;
  new(hx);
  hx^.v := 60;
  hx^.next := nil;
  new(tx);
  tx^.v := 40;
  tx^.next := hx;
  hx := tx;
  Out.Int(hx^.v + hx^.next^.v, 0);
  Out.Ln;
  Geom.Translate(a, 1, 2);
  Out.Int(a.x + a.y, 0);
  Out.Ln;
  tx := Geom.Next(hx);
  Out.Int(tx^.v, 0);
  Out.Ln;
  a.Scale(3);
  Out.Int(a.x + a.y, 0);
  Out.Ln;
  Out.Int(a.Sum(), 0);
  Out.Ln;
  w[0] := 5;
  w[1] := 7;
  w[2] := 9;
  w[3] := 11;
  Out.Int(w[0] + w[3], 0);
  Out.Ln;
  Geom.Fill(w, 100);
  Out.Int(w[0] + w[3], 0);
  Out.Ln;
  a.x := 30;
  a.y := 25;
  Geom.origin := a;
  Out.Int(Geom.origin.x + Geom.origin.y, 0);
  Out.Ln;
  Geom.origin.x := 88;
  Geom.origin.y := 11;
  a.x := 0;
  a.y := 0;
  a := Geom.origin;
  Out.Int(a.x + a.y, 0);
  Out.Ln;
  px.x := 10;
  px.y := 4;
  px.z := 1;
  px.Scale(2);
  px.AddZ(3);
  Out.Int(px.x + px.y + px.z, 0);
  Out.Ln;
  rg.p.x := 5;
  rg.p.y := 6;
  rg.q.x := 1;
  rg.q.y := 2;
  rg.w := 3;
  Out.Int(rg.p.x + rg.p.y + rg.q.x + rg.q.y + rg.w, 0);
  Out.Ln;
  Out.Int(Strings.Pos("lo", "hello") + 999, 0);
  Out.Ln;
  Texts.OpenWriter(tw);
  Texts.WriteString(tw, "tx:");
  Texts.WriteInt(tw, 5, 0);
  Texts.WriteLn(tw);
  bx.x := 10;
  bx.y := 20;
  bx.z := 9;
  Out.Int(bx.Sum(), 0);
  Out.Ln;
  Geom.marks := {1, 3};
  if 2 IN Geom.marks then Out.Int(26, 0) else Out.Int(27, 0) end;
  Out.Ln;
  Geom.marks := Geom.marks + {2};
  if 2 IN Geom.marks then Out.Int(28, 0) end;
  Out.Ln;
  fd := Files.Old("RD0:Tests/O2cLib/Sample.txt");
  Files.Open(rr, fd);
  fi := 0;
  while (fi < 63) & ~rr.eof do
    Files.Read(rr, cc);
    if ~rr.eof then
      fl[fi] := cc;
      fi := fi + 1
    end
  end;
  fl[fi] := CHR(0);
  Out.String(fl);
  Out.Ln;
  Files.Wait("BD0:");
  Files.Delete("BD0:O2cDemo.TXT");
  Files.Delete("BD0:O2cRen.TXT");
  fd := Files.New("BD0:O2cDemo.TXT");
  Files.Open(rr, fd);
  Files.WriteString(rr, "O2cW!");
  if rr.res = 0 then Out.String("res-ok") else Out.String("res-bad") end;
  Out.Ln;
  Files.Close(rr);
  Files.Rename("BD0:O2cDemo.TXT", "BD0:O2cRen.TXT");
  fd := Files.Old("BD0:O2cRen.TXT");
  Files.Set(rr, fd, 0);
  fi := 0;
  while (fi < 63) & ~rr.eof do
    Files.Read(rr, cc);
    if ~rr.eof then
      fl[fi] := cc;
      fi := fi + 1
    end
  end;
  fl[fi] := CHR(0);
  Out.String(fl);
  Out.Ln;
  In.Open;
  In.Int(m);
  if In.Done then Out.Int(m, 0) else Out.String("in-eof") end;
  Out.Ln;
  r := Math.ln(Math.e);
  if (r > 0.99) & (r < 1.01) then Out.Int(71, 0) else Out.Int(72, 0) end;
  Out.Ln;
  r := Math.sin(Math.pi / 2.0);
  if (r > 0.99) & (r < 1.01) then Out.Int(73, 0) else Out.Int(74, 0) end;
  Out.Ln;
  r := Math.log(8.0, 2.0);
  if (r > 2.9) & (r < 3.1) then Out.Int(75, 0) else Out.Int(76, 0) end;
  Out.Ln;
  r := Math.arctan2(1.0, 1.0);
  if (r > 0.7) & (r < 0.87) then Out.Int(77, 0) else Out.Int(78, 0) end;
  Out.Ln;
  Reals.Convert(2.5, fl);
  Out.String(fl);
  Out.Ln;
  r := 0.0;
  Reals.ConvertTo(r, "3.25");
  Out.Real(r, 0);
  Out.Ln;
  Out.Int(Reals.Expo(250.0), 0);
  Out.Ln;
  Term.SetColor(2, 0);
  Term.Reset;
  Out.String("term-ok");
  Out.Ln;
  Input.Read(ch);
  Out.Int(8000 + ORD(ch) + Input.Available, 0);
  Out.Ln;
  if Input.Time > 0 then Out.Int(8001, 0) else Out.Int(8011, 0) end;
  Out.Ln;
  Input.Mouse(s2, n, m);
  if (s2 = {}) & (n = 0) & (m = 0) then
    Out.Int(8002, 0)
  else
    Out.Int(8012, 0)
  end;
  Out.Ln;
  if Input.TimeUnit = 1000 then Out.Int(8003, 0) else Out.Int(8013, 0) end;
  Out.Ln;
  lre := MathL.ln(MathL.e);
  Out.LongReal(lre, 0);
  Out.Ln;
  Out.LongReal(MathL.power(2.0D0, 3.0D0), 0);
  Out.Ln;
  Out.LongReal(MathL.pi, 0);
  Out.Ln;
  Env.Set("O2CENV", "hello-env");
  Env.Get("O2CENV", fl);
  Out.String(fl);
  Out.Ln;
  Env.Get("O2CNOPE", fl);
  if fl[0] = CHR(0) then Out.Int(8300, 0) else Out.Int(8301, 0) end;
  Out.Ln;
  Out.Int(8200 + Args.count, 0);
  Out.Ln;
  Args.Get(9999, fl, n);
  if n = -1 then Out.Int(8210, 0) else Out.Int(8213, 0) end;
  Out.Ln;
  Args.Get(1, fl, n);
  if n = -1 then Out.Int(8212, 0) else Out.Int(8211, 0) end;
  Out.Ln;
  Err.Write("err-ok");
  Err.WriteLn;
  XYplane.Open;
  XYplane.Dot(3, 4, XYplane.draw);
  if XYplane.IsDot(3, 4) then Out.Int(8100, 0) else Out.Int(8101, 0) end;
  Out.Ln;
  XYplane.Dot(3, 4, XYplane.erase);
  if XYplane.IsDot(3, 4) then Out.Int(8102, 0) else Out.Int(8103, 0) end;
  Out.Ln;
  XYplane.Clear;
  if XYplane.IsDot(3, 4) then Out.Int(8104, 0) else Out.Int(8105, 0) end;
  Out.Ln;
  Out.Int(Geom.SumArr(w), 0);
  Out.Ln
end Hello.
