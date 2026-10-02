## Dump the Heartwick map on a 50-unit grid as CSV (x,z,height,water,blocked) plus heart and home rows.
import game, sim, topography, seat_view
let w = newWorld(2026)
echo "kind,x,z,height,water,blocked"
for h in w.controlHearts: echo "heart,", h.pos.x, ",", h.pos.z, ",0,0,0"
for s in 0..1: echo "home", s, ",", home(s).x, ",", home(s).z, ",0,0,0"
var z = minZ()
while z < maxZ():
  var x = minX()
  while x < maxX():
    let wet = riverBlend(x, z) > 0 and terrainHeight(x, z) < RiverWaterHeight
    echo "g,", x, ",", z, ",", terrainHeight(x, z), ",", int(wet), ",", int(w.blocked(point(x, z), 0))
    x += 100
  z += 100
