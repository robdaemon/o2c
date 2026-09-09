module Geo;
import Math;
type Rect* = record p*, q*: Math.Point; w*: integer end;
type Box* = record (Math.Point) z*: integer end;
procedure (var bx: Box) Sum*: integer;
begin
  return bx.x + bx.y + bx.z
end Sum;
end Geo.
