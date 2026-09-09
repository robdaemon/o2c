with Aegir_User.Console;
with Ada.Exceptions;
with O2c_Compiler;

--  o2c entry point (M2 subset).  Compiles the embedded demo module
--  and prints the generated Ada, one prefixed line at a time, between
--  markers, so a test boot can capture it and the host build can
--  reconstruct the file exactly.
--
--  The demo exercises module vars, a constant expression, an
--  assignment, an expression call argument, and a procedure with a
--  value and a VAR parameter.
procedure O2c is

  Sample : constant String :=
    "module Hello;" & ASCII.LF &
    "import Out;" & ASCII.LF &
    ASCII.LF &
    "type Vector = array 4 of integer;" & ASCII.LF &
    "type Pair = record a, b: integer end;" & ASCII.LF &
    "type Line = array 8 of char;" & ASCII.LF &
    "type Node = pointer to NodeDesc;" & ASCII.LF &
    "type NodeDesc = record v: integer; next: Node end;" & ASCII.LF &
    "type Shape = record x: integer end;" & ASCII.LF &
    "type Circle = record (Shape) r: integer end;" & ASCII.LF &
    "type PShape = pointer to Shape;" & ASCII.LF &
    "type PCircle = pointer to Circle;" & ASCII.LF &
    ASCII.LF &
    "var n: integer;" & ASCII.LF &
    "var v: Vector; p: Pair; q: Pair; i: integer;" & ASCII.LF &
    "var msg: Line; ch: char;" & ASCII.LF &
    "var head, cur: Node;" & ASCII.LF &
    "var shp: PShape; circ: PCircle;" & ASCII.LF &
    ASCII.LF &
    "const Greeting = ""hello from Oberon-2"";" & ASCII.LF &
    ASCII.LF &
    "procedure CountTo(k: integer; var total: integer);" & ASCII.LF &
    "begin" & ASCII.LF &
    "  total := 0;" & ASCII.LF &
    "  while total < k * 2 do" & ASCII.LF &
    "    total := total + 1" & ASCII.LF &
    "  end;" & ASCII.LF &
    "  if total = k * 2 then" & ASCII.LF &
    "    Out.Int(total, 0);" & ASCII.LF &
    "    Out.Ln" & ASCII.LF &
    "  else" & ASCII.LF &
    "    Out.Int(0, 0);" & ASCII.LF &
    "    Out.Ln" & ASCII.LF &
    "  end" & ASCII.LF &
    "end CountTo;" & ASCII.LF &
    ASCII.LF &
    "procedure Square(x: integer): integer;" & ASCII.LF &
    "begin" & ASCII.LF &
    "  return x * x" & ASCII.LF &
    "end Square;" & ASCII.LF &
    ASCII.LF &
    "procedure UpTo12;" & ASCII.LF &
    "  const Goal = 12;" & ASCII.LF &
    "  var k: integer;" & ASCII.LF &
    "begin" & ASCII.LF &
    "  k := 9;" & ASCII.LF &
    "  loop" & ASCII.LF &
    "    k := k + 1;" & ASCII.LF &
    "    if k = Goal then exit end" & ASCII.LF &
    "  end;" & ASCII.LF &
    "  Out.Int(k, 0);" & ASCII.LF &
    "  Out.Ln" & ASCII.LF &
    "end UpTo12;" & ASCII.LF &
    ASCII.LF &
    "procedure Dot;" & ASCII.LF &
    "  type Pt = pointer to Point;" & ASCII.LF &
    "  type Point = record x, y: integer end;" & ASCII.LF &
    "  var q: Pt; d: integer;" & ASCII.LF &
    "begin" & ASCII.LF &
    "  new(q);" & ASCII.LF &
    "  q^.x := 3;" & ASCII.LF &
    "  q^.y := 4;" & ASCII.LF &
    "  d := q^.x + q^.y;" & ASCII.LF &
    "  Out.Int(d, 0);" & ASCII.LF &
    "  Out.Ln" & ASCII.LF &
    "end Dot;" & ASCII.LF &
    ASCII.LF &
    "procedure Push(var l: Node; v: integer);" & ASCII.LF &
    "  var n: Node;" & ASCII.LF &
    "begin" & ASCII.LF &
    "  new(n);" & ASCII.LF &
    "  n^.v := v;" & ASCII.LF &
    "  n^.next := l;" & ASCII.LF &
    "  l := n" & ASCII.LF &
    "end Push;" & ASCII.LF &
    ASCII.LF &
    "procedure SwapPair(var r: Pair);" & ASCII.LF &
    "  var t: integer;" & ASCII.LF &
    "begin" & ASCII.LF &
    "  t := r.a;" & ASCII.LF &
    "  r.a := r.b;" & ASCII.LF &
    "  r.b := t" & ASCII.LF &
    "end SwapPair;" & ASCII.LF &
    ASCII.LF &
    "procedure Last(l: Node): Node;" & ASCII.LF &
    "  var r: Node;" & ASCII.LF &
    "begin" & ASCII.LF &
    "  r := l;" & ASCII.LF &
    "  if r # nil then" & ASCII.LF &
    "    while r^.next # nil do" & ASCII.LF &
    "      r := r^.next" & ASCII.LF &
    "    end" & ASCII.LF &
    "  end;" & ASCII.LF &
    "  return r" & ASCII.LF &
    "end Last;" & ASCII.LF &
    ASCII.LF &
    "procedure Sum(l: Node): integer;" & ASCII.LF &
    "  var r: Node; t: integer;" & ASCII.LF &
    "begin" & ASCII.LF &
    "  r := l;" & ASCII.LF &
    "  t := 0;" & ASCII.LF &
    "  while r # nil do" & ASCII.LF &
    "    t := t + r^.v;" & ASCII.LF &
    "    r := r^.next" & ASCII.LF &
    "  end;" & ASCII.LF &
    "  return t" & ASCII.LF &
    "end Sum;" & ASCII.LF &
    ASCII.LF &
    "procedure FillArr(var a: array of integer; start: integer);" & ASCII.LF &
    "  var j: integer;" & ASCII.LF &
    "begin" & ASCII.LF &
    "  for j := 0 to len(a) - 1 do" & ASCII.LF &
    "    a[j] := start + j" & ASCII.LF &
    "  end" & ASCII.LF &
    "end FillArr;" & ASCII.LF &
    ASCII.LF &
    "procedure SumArr(a: array of integer): integer;" & ASCII.LF &
    "  var j, t: integer;" & ASCII.LF &
    "begin" & ASCII.LF &
    "  t := 0;" & ASCII.LF &
    "  for j := 0 to len(a) - 1 do" & ASCII.LF &
    "    t := t + a[j]" & ASCII.LF &
    "  end;" & ASCII.LF &
    "  return t" & ASCII.LF &
    "end SumArr;" & ASCII.LF &
    ASCII.LF &
    "procedure CLen(s: array of char): integer;" & ASCII.LF &
    "begin" & ASCII.LF &
    "  return len(s)" & ASCII.LF &
    "end CLen;" & ASCII.LF &
    ASCII.LF &
    "procedure (var s: Shape) Widen (k: integer);" & ASCII.LF &
    "begin" & ASCII.LF &
    "  s.x := s.x + k" & ASCII.LF &
    "end Widen;" & ASCII.LF &
    ASCII.LF &
    "procedure (var c: Circle) Widen (k: integer);" & ASCII.LF &
    "begin" & ASCII.LF &
    "  c.r := c.r + k" & ASCII.LF &
    "end Widen;" & ASCII.LF &
    ASCII.LF &
    ASCII.LF &
    "begin" & ASCII.LF &
    "  n := 0;" & ASCII.LF &
    "  repeat" & ASCII.LF &
    "    n := n + 1;" & ASCII.LF &
    "    Out.Int(n, 0)" & ASCII.LF &
    "  until n = 3;" & ASCII.LF &
    "  Out.Ln;" & ASCII.LF &
    "  Out.String(Greeting);" & ASCII.LF &
    "  Out.Ln;" & ASCII.LF &
    "  for n := 4 to 5 do" & ASCII.LF &
    "    Out.Int(n, 0)" & ASCII.LF &
    "  end;" & ASCII.LF &
    "  Out.Ln;" & ASCII.LF &
    ASCII.LF &
    "  Out.Int(Square(3), 0);" & ASCII.LF &
    "  Out.Ln;" & ASCII.LF &
    "  i := 0;" & ASCII.LF &
    "  while i < 4 do" & ASCII.LF &
    "    v[i] := i * i;" & ASCII.LF &
    "    i := i + 1" & ASCII.LF &
    "  end;" & ASCII.LF &
    "  i := 0;" & ASCII.LF &
    "  repeat" & ASCII.LF &
    "    Out.Int(v[i], 0);" & ASCII.LF &
    "    i := i + 1" & ASCII.LF &
    "  until i = 4;" & ASCII.LF &
    "  Out.Ln;" & ASCII.LF &
    "  p.a := 7;" & ASCII.LF &
    "  p.b := Square(p.a) - 1;" & ASCII.LF &
    "  Out.Int(p.b, 0);" & ASCII.LF &
    "  Out.Ln;" & ASCII.LF &
    "  q := p;" & ASCII.LF &
    "  Out.Int(q.b, 0);" & ASCII.LF &
    "  Out.Ln;" & ASCII.LF &
    "  SwapPair(p);" & ASCII.LF &
    "  Out.Int(p.a, 0);" & ASCII.LF &
    "  Out.Ln;" & ASCII.LF &
    "  Out.Int(p.b, 0);" & ASCII.LF &
    "  Out.Ln;" & ASCII.LF &
    "  msg := ""hi"";" & ASCII.LF &
    "  msg[0] := ""H"";" & ASCII.LF &
    "  Out.String(msg);" & ASCII.LF &
    "  Out.Ln;" & ASCII.LF &
    "  ch := msg[0];" & ASCII.LF &
    "  if ch = ""H"" then" & ASCII.LF &
    "    Out.Int(7, 0);" & ASCII.LF &
    "    Out.Ln" & ASCII.LF &
    "  end" & ASCII.LF &
    "  i := 2;" & ASCII.LF &
    "  case i of" & ASCII.LF &
    "    0: Out.Int(0, 0)" & ASCII.LF &
    "  | 1: Out.String(""one"")" & ASCII.LF &
    "  | 2, 3: Out.Int(i, 0)" & ASCII.LF &
    "  else" & ASCII.LF &
    "    Out.Int(9, 0)" & ASCII.LF &
    "  end;" & ASCII.LF &
    "  Out.Ln" & ASCII.LF &
    "  CountTo(21, n);" & ASCII.LF &
    "  head := nil;" & ASCII.LF &
    "  Push(head, 1);" & ASCII.LF &
    "  Push(head, 2);" & ASCII.LF &
    "  Push(head, 3);" & ASCII.LF &
    "  cur := Last(head);" & ASCII.LF &
    "  Out.Int(head^.v, 0);" & ASCII.LF &
    "  Out.Ln;" & ASCII.LF &
    "  Out.Int(cur^.v, 0);" & ASCII.LF &
    "  Out.Ln;" & ASCII.LF &
    "  Out.Int(Sum(head), 0);" & ASCII.LF &
    "  Out.Ln;" & ASCII.LF &
    "  FillArr(v, 5);" & ASCII.LF &
    "  Out.Int(SumArr(v), 0);" & ASCII.LF &
    "  Out.Ln;" & ASCII.LF &
    "  Out.Int(len(v), 0);" & ASCII.LF &
    "  Out.Ln;" & ASCII.LF &
    "  Out.Int(CLen(msg), 0);" & ASCII.LF &
    "  Out.Ln;" & ASCII.LF &
    "  UpTo12;" & ASCII.LF &
    "  Dot;" & ASCII.LF &
    "  new(shp);" & ASCII.LF &
    "  shp^.x := 0;" & ASCII.LF &
    "  new(circ);" & ASCII.LF &
    "  circ^.x := 10;" & ASCII.LF &
    "  circ^.r := 1;" & ASCII.LF &
    "  shp.Widen(7);" & ASCII.LF &
    "  Out.Int(shp^.x, 0);" & ASCII.LF &
    "  Out.Ln;" & ASCII.LF &
    "  circ.Widen(4);" & ASCII.LF &
    "  Out.Int(circ^.r, 0);" & ASCII.LF &
    "  Out.Ln;" & ASCII.LF &
    "  if circ IS Circle then" & ASCII.LF &
    "    with circ: Circle do" & ASCII.LF &
    "      circ^.r := circ^.r + 2" & ASCII.LF &
    "    end;" & ASCII.LF &
    "    Out.Int(circ^.r, 0);" & ASCII.LF &
    "    Out.Ln" & ASCII.LF &
    "  end" & ASCII.LF &
    "end Hello.";


   procedure Emit_Line (Line : String) is
   begin
      Aegir_User.Console.Put_Line ("O2C|" & Line);
   end Emit_Line;

   procedure Emit_Gen (G : String) is
      Start : Positive := G'First;
      I     : Positive := G'First;
   begin
      while I <= G'Last loop
         if G (I) = ASCII.LF then
            Emit_Line (G (Start .. I - 1));
            Start := I + 1;
         end if;
         I := I + 1;
      end loop;
      if Start <= G'Last then
         Emit_Line (G (Start .. G'Last));
      end if;
   end Emit_Gen;

begin
   Aegir_User.Console.Set_Endpoint (1);
   Aegir_User.Console.Put_Line ("o2c 0.2 (Oberon-2 to Ada for Aegir)");
   Aegir_User.Console.Put_Line ("--- ada begin ---");
   declare
      Gen : constant String := O2c_Compiler.Compile (Sample);
   begin
      Emit_Gen (Gen);
   exception
      when E : O2c_Compiler.O2c_Error =>
         Aegir_User.Console.Put_Line
           ("o2c error: " & Ada.Exceptions.Exception_Message (E));
   end;
   Aegir_User.Console.Put_Line ("--- ada end ---");
end O2c;
