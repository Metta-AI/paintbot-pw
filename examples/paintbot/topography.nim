## Centimetre terrain heights, shared by simulation and the Polyworld layers.
const TerraceHeight* = 250
var wideRamps* = false
var wilderness* = false
var deepWilderness* = false
proc terraceHeight*(x, z: int): int =
  if x >= 1000 and x <= 2200 and z >= 200 and z <= 1200:
    let dx = max(abs(x-1600)-450, 0)
    let dz = max(abs(z-700)-350, 0)
    if dx*dx+dz*dz <= 150*150: return TerraceHeight
  if z >= (if wideRamps: 500 else: 750) and z <= (if wideRamps: 1100 else: 950):
    if x >= 600 and x < 1000: return (x-600)*TerraceHeight div 400
    if x > 2200 and x <= 2800: return (2800-x)*TerraceHeight div 600
proc forestRouteDistance*(x,z:int):int =
  # Four-metre woodland trails loop around the village with links at both ends.
  min(min(abs(x+1700),abs(x-8100)),min(abs(z+650),abs(z-4650)))
proc forestHeight*(x,z:int):int =
  var height=0
  for c in [(-1900,700,600,1100),(-1400,3100,480,1000),
      (800,-900,380,1000),(3600,-900,460,1100),(5700,-800,330,900)]:
    for mirrored in [false,true]:
      let cx=if mirrored:6400-c[0] else:c[0]
      let cz=if mirrored:4000-c[1] else:c[1]
      let d2=(x-cx)*(x-cx)+(z-cz)*(z-cz)
      if d2<c[3]*c[3]:
        height=max(height,c[2]*(c[3]*c[3]-d2) div (c[3]*c[3]))
  # Broad saddles lower the route while leaving climbable slopes on either side.
  height=height*(300+min(forestRouteDistance(x,z),500)) div 800
  let edge=max(max(0,max(-x,x-6400)),max(0,max(-z,z-4000)))
  height*min(edge,500) div 500
proc forestLots*():seq[tuple[x,z,radius:int]] =
  # Jittered groves, not a wall: trails and objective clearings stay open.
  for z in countup(-1000,4800,400):
    for x in countup(-2500,8900,400):
      if x>= -800 and x<=7200 and z>= -400 and z<=4400:continue
      let px=x+((x+3000)*17+(z+1400)*11) mod 161-80
      let pz=z+((x+3000)*7+(z+1400)*19) mod 181-90
      if forestRouteDistance(px,pz)<220:continue
      if abs(pz-2000)<240:continue
      if (x+z) mod 3==0:continue
      result.add (px,pz,55+(abs(x+z) mod 30))
proc wildernessHeight*(x,z:int):int =
  if not wilderness or (x>=0 and x<=6400 and z>=0 and z<=4000):return 0
  if deepWilderness:return forestHeight(x,z)
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
