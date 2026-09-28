## CC0 village props and generated woodland fitted to solid lots.
import std/math
import vmath
import polyworld/quadterrain
import scenery, sim, village

proc placeMapScenery*(scenery: Scenery) =
  ## Rules 41 maps: every round cover lot gets the prop its kind names, sized to its
  ## footprint; a mirrored pair faces opposite ways.
  let
    pack = scenery.homes
    grove = scenery.plants
    rocks = scenery.rocks
    trees = TreeNames
    bushes = BushNames
    houses = HouseNames
  for i, c in currentMap().cover:
    let k = i div 2
    let r = c.w.float32/200
    let x = c.x.float32+c.w.float32/2
    let z = c.z.float32+c.w.float32/2
    let p = vec3(x/100-32, terrainHeight(x.int, z.int).float32/100, z/100-20)
    let turn = k.float32*0.7+(if i mod 2 == 1: PI.float32 else: 0'f32)
    case c.kind
    of mapTree:
      if k mod 5 == 0:
        grove.placeProp(bushes[k mod bushes.len], p, turn, r*2.2)
      else:
        grove.placeProp(trees[k mod trees.len], p, turn, 3.5+(k mod 5).float32*0.55)
      if k mod 3 == 0:
        scenery.details.placeProp(FlowerNames[(1+k mod 3 - 1) mod 3], p+vec3(0.8, 0, 0.5), turn, 0.8)
    of mapHouse:
      pack.placeProp(houses[k mod houses.len], p, turn, r)
    of mapProp:
      if k mod 2 == 0: pack.placeProp("round-garden", p, turn, r)
      else: grove.placeProp(bushes[k mod bushes.len], p, turn, r*2.2)
    of mapRock:
      rocks.placeProp(RockNames[k mod 3], p, turn, r*1.9)

proc placeRoundVillage*(scenery: Scenery) =
  ## Places CC0 cottages, generated woodland, and original flower patches.
  let
    pack = scenery.homes
    grove = scenery.plants
    rocks = scenery.rocks
    trees = TreeNames
    bushes = BushNames
  proc at(x, z: float32): Vec3 =
    vec3(x/100-32, (if visionRulesVersion >= 9: terrainHeight(x.int,
        z.int).float32/100 else: 0'f32), z/100-20)
  for i, lot in roundVillage():
    let p = at(lot.x.float32, lot.z.float32)
    let r = lot.radius.float32/100
    if i in [0, 1, 4, 5]:
      let node = case i
        of 0: "round-cottage"
        of 1: "mushroom-house"
        of 4: "stump-house"
        else: "spiral-house"
      pack.placeProp(node, p, i.float32*0.5, r)
      if i != 1:
        for j in 0..<3:
          let a=j.float32*2.1
          scenery.details.placeProp(FlowerNames[(j+1 - 1) mod 3],
              p+vec3(cos(a)*r*0.65,r*1.65,sin(a)*r*0.65),a,0.38)
      # Trailing moss and flower beds soften the foundations.
      for j in 0..<4:
        let a = j.float32*1.6+i.float32
        scenery.details.placeProp(FlowerNames[(1+j mod 3 - 1) mod 3],
            p+vec3(cos(a)*r, 0, sin(a)*r), a, 0.38)
    elif i in [2, 3, 8, 9, 12, 13]:
      let treeIndex = [2, 3, 8, 9, 12, 13].find(i)
      grove.placeProp(trees[treeIndex], p, i.float32, if i <
          6: 8'f32 else: 5.5'f32)
      grove.placeProp(bushes[treeIndex mod 4], p, treeIndex.float32, r*1.8)
      for j in 0..<5:
        let a = i.float32+j.float32*1.3
        scenery.details.placeProp(FlowerNames[(1+j mod 3 - 1) mod 3],
            p+vec3(cos(a)*r, 0, sin(a)*r), a, 0.6)
    elif i in [6, 7]:
      pack.placeProp("round-garden", p, i.float32, r)
    else:
      grove.placeProp(bushes[(i-10) mod 4], p, i.float32, r*2.2)
      scenery.details.placeProp(FlowerNames[(1+i mod 3 - 1) mod 3], p, 0, r*0.5)
  if visionRulesVersion >= 9:
    # Mossy exposed stone on terrace banks. Ramp mouths remain clear.
    for side in 0..1:
      for j in 0..<11:
        let x = 1060+j*108
        let z = if j mod 2 == 0: 245 else: 1170
        let px = if side == 0: x else: 6400-x
        let pz = if side == 0: z else: 4000-z
        let p = vec3(px.float32/100-32, 0.25, pz.float32/100-20)
        rocks.placeProp(RockNames[j mod 3], p, j.float32, 2.2)
        scenery.details.placeProp("eave_clover", p+vec3(0, 1.5, 0), j.float32, 1.1)
  # Distinct broadleaf silhouettes break up the conifer boundary.
  for i in 0..<6:
    let x = 700+i*1000
    let z = if i mod 2 == 0: minZ()-100 else: maxZ()+100
    if islandTerrain:continue
    grove.placeProp(trees[i], at(x.float32, z.float32), i.float32, 7.5)
  for i in 0..<38:
    let x = 350+(i*157 mod 5600)
    let z = if i mod 2 == 0: 100+(i*31 mod 130) else: 3750+(i*17 mod 100)
    scenery.details.placeProp(FlowerNames[(1+i mod 3 - 1) mod 3], at(x.float32,
        z.float32), i.float32, 0.5)

  if wilderness:
    for i,p in [point(-620,300),point(-620,1700),point(-620,3500),point(1200,-320),point(3100,-320),point(5400,-320)]:
      for q in [p,point(6400-p.x.int,4000-p.z.int)]:
        if riverBlend(q.x.int,q.z.int)>0: continue
        let base=at(q.x.float32,q.z.float32)
        grove.placeProp(trees[i mod trees.len],base,i.float32*1.2,3.2)
        grove.placeProp(bushes[i mod bushes.len],base+vec3(0.5,0,0.3),i.float32,0.65)

  if deepWilderness:
    for i,lot in forestLots():
      let p=at(lot.x.float32,lot.z.float32)
      if i mod 4==0:
        grove.placeProp(bushes[i mod bushes.len],p,i.float32*0.7,1.7)
      else:
        grove.placeProp(trees[i mod trees.len],p,i.float32*0.7,3.5+(i mod 5).float32*0.55)
      if i mod 3==0:
        scenery.details.placeProp(FlowerNames[(1+i mod 3 - 1) mod 3],p+vec3(0.8,0,0.5),i.float32,0.8)

proc placeVillage*(world: World, scenery: Scenery) =
  ## Fits our cottages and market props to historical replay obstacles.
  proc fit(pack: PropPack, name: string, cover: Cover, height: float32,
      reversed: bool) =
    ## Preserves the recorded obstacle footprint while replacing its artwork.
    let dimensions = pack.propDimensions(name)
    pack.placeProp(
      name,
      vec3((cover.x.float32 + cover.w.float32 / 2) / 100 - 32, 0,
        (cover.z.float32 + cover.h.float32 / 2) / 100 - 20),
      if reversed: PI.float32 else: 0.0'f,
      1,
      vec3(1),
      vec3(cover.w.float32 / 100 / dimensions.x, height / dimensions.y,
        cover.h.float32 / 100 / dimensions.z)
    )
  for i, cover in world.cover:
    let
      kind =
        if i div 2 < VillageLots.len: VillageLots[i div 2].kind
        else: well
      reversed = i mod 2 == 1
    case kind
    of cottage:
      fit(scenery.homes, HouseNames[i div 2 mod 4], cover, 5.2, reversed)
    of bakery:
      fit(scenery.homes, "mushroom-house", cover, 5.8, reversed)
    of gardenWall:
      fit(scenery.homes, "round-garden", cover, 0.7, reversed)
    of cart:
      fit(scenery.details, "market", cover, 1.8, reversed)
    of supplies:
      fit(scenery.details, "beehive", cover, 1.8, reversed)
    of well:
      fit(scenery.well, "Well", cover, 2.8, reversed)
  for x in [-26.0'f, -13, 0, 13, 26]:
    for z in [-22.0'f, 22]:
      scenery.details.placeProp("bucket_planter", vec3(x, 0, z), 0, 0.7)
  for side in 0 .. 1:
    for j in 0 ..< 9:
      let
        x = 13.0'f + j.float32 * 0.65'f
        z = 10.1'f
        position =
          if side == 0: vec3(x - 32, 0, z - 20)
          else: vec3(32 - x, 0, 20 - z)
      scenery.details.placeProp(
        FlowerNames[j mod 3], position, j.float32, 0.35
      )
