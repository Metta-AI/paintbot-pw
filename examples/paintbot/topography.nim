## Centimetre terrain heights, shared by simulation and the Polyworld layers.
const TerraceHeight* = 250
proc terraceHeight*(x, z: int): int =
  if x >= 1000 and x <= 2200 and z >= 200 and z <= 1200:
    let dx = max(abs(x-1600)-450, 0)
    let dz = max(abs(z-700)-350, 0)
    if dx*dx+dz*dz <= 150*150: return TerraceHeight
  if z >= 750 and z <= 950:
    if x >= 600 and x < 1000: return (x-600)*TerraceHeight div 400
    if x > 2200 and x <= 2800: return (2800-x)*TerraceHeight div 600
proc raisedHeight*(x, z: int): int =
  max(terraceHeight(x, z), terraceHeight(6400-x, 4000-z))
proc terrainHeight*(x, z: int): int =
  let raised = raisedHeight(x, z)
  if raised > 0: return raised
  # Sunken lane with sloping entrances, crossed by a level central causeway.
  let along = clamp(min(x-1400, 5000-x), 0, 400)
  let across = clamp(500-abs(z-2000), 0, 250)
  let crossing = clamp(abs(x-3200)-160, 0, 240)
  int(-150'i64*along.int64*across.int64*crossing.int64 div (400*250*240))
