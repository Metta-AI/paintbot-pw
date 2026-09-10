## Centimetre terrain heights, shared by simulation and the Polyworld layers.
const TerraceHeight* = 250
var wideRamps* = false
var wilderness* = false
proc terraceHeight*(x, z: int): int =
  if x >= 1000 and x <= 2200 and z >= 200 and z <= 1200:
    let dx = max(abs(x-1600)-450, 0)
    let dz = max(abs(z-700)-350, 0)
    if dx*dx+dz*dz <= 150*150: return TerraceHeight
  if z >= (if wideRamps: 500 else: 750) and z <= (if wideRamps: 1100 else: 950):
    if x >= 600 and x < 1000: return (x-600)*TerraceHeight div 400
    if x > 2200 and x <= 2800: return (2800-x)*TerraceHeight div 600
proc wildernessHeight*(x,z:int):int =
  if not wilderness or (x>=0 and x<=6400 and z>=0 and z<=4000):return 0
  # Smooth hills with wide low saddles; none of the perimeter routes is a cliff.
  for center in [(-500,900),(-500,3100),(6900,900),(6900,3100),(1700,-250),(4700,4250)]:
    let d=abs(x-center[0])+abs(z-center[1])
    result=max(result,max(0,180-d div 3))
  let edge=min(min(abs(x),abs(x-6400)),min(abs(z),abs(z-4000)))
  result=min(result,edge div 2)
proc raisedHeight*(x, z: int): int =
  max(terraceHeight(x, z), terraceHeight(6400-x, 4000-z))
proc terrainHeight*(x, z: int): int =
  if wilderness and (x<0 or x>6400 or z<0 or z>4000):return wildernessHeight(x,z)
  let raised = raisedHeight(x, z)
  if raised > 0: return raised
  # Sunken lane with sloping entrances, crossed by a level central causeway.
  let along = clamp(min(x-1400, 5000-x), 0, 400)
  let across = clamp(500-abs(z-2000), 0, 250)
  let crossing = clamp(abs(x-3200)-160, 0, 240)
  int(-150'i64*along.int64*across.int64*crossing.int64 div (400*250*240))
