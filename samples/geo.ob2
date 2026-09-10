module Geo;
import Geom;
type Rect* = record p*, q*: Geom.Point; w*: integer end;
type Box* = record (Geom.Point) z*: integer end;
procedure (var bx: Box) Sum*: integer;
begin
  return bx.x + bx.y + bx.z
end Sum;
end Geo.
