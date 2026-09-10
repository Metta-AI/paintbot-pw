## Heartleaf's Golden Valley and Enchanted Meadow art, fitted to solid lots.
import std/[math, sequtils]
import vmath
import polyworld/[common, quadterrain]
import sim, village

proc placeRoundVillage*() =
  let pack = loadPropPack(when defined(emscripten): "/round-village.glb" else: "tmp/round-village.glb",
      unitHeight = false, textured = false)
  let grove = loadPropPack(DataRoot & "/terrain/toon_enchanted_meadow/vegetation.glb",
      unitHeight = true, textured = true, maxTextureSize = 512, only = @["tree_01a","tree_02a","tree_03a","tree_04a","tree_05a","tree_06a","bush_01a","bush_02a","flower_bush_01a","flower_bush_02a","flowers_patch_01a","flowers_patch_02a","flowers_patch_03a","ivy_01a"])
  let rocks = loadPropPack(DataRoot & "/terrain/toon_enchanted_meadow/rocks.glb",
      unitHeight = true, textured = true, maxTextureSize = 512, only = @["rock_medium_01a","rock_medium_02a","rock_medium_03a"])
  let trees = ["tree_01a", "tree_02a", "tree_03a", "tree_04a", "tree_05a", "tree_06a"]
  let bushes = ["bush_01a", "bush_02a", "flower_bush_01a", "flower_bush_02a"]
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
          grove.placeProp("flowers_patch_0" & $(j+1) & "a",
              p+vec3(cos(a)*r*0.65,r*1.65,sin(a)*r*0.65),a,0.38)
      # Trailing moss and flower beds soften the foundations.
      for j in 0..<4:
        let a = j.float32*1.6+i.float32
        grove.placeProp("flowers_patch_0" & $(1+j mod 3) & "a",
            p+vec3(cos(a)*r, 0, sin(a)*r), a, 0.38)
    elif i in [2, 3, 8, 9, 12, 13]:
      let treeIndex = [2, 3, 8, 9, 12, 13].find(i)
      grove.placeProp(trees[treeIndex], p, i.float32, if i <
          6: 8'f32 else: 5.5'f32)
      grove.placeProp(bushes[treeIndex mod 4], p, treeIndex.float32, r*1.8)
      for j in 0..<5:
        let a = i.float32+j.float32*1.3
        grove.placeProp("flowers_patch_0" & $(1+j mod 3) & "a",
            p+vec3(cos(a)*r, 0, sin(a)*r), a, 0.6)
    elif i in [6, 7]:
      pack.placeProp("round-garden", p, i.float32, r)
    else:
      grove.placeProp(bushes[(i-10) mod 4], p, i.float32, r*2.2)
      grove.placeProp("flowers_patch_0" & $(1+i mod 3) & "a", p, 0, r*0.5)
  if visionRulesVersion >= 9:
    # Mossy exposed stone on terrace banks. Ramp mouths remain clear.
    for side in 0..1:
      for j in 0..<11:
        let x = 1060+j*108
        let z = if j mod 2 == 0: 245 else: 1170
        let px = if side == 0: x else: 6400-x
        let pz = if side == 0: z else: 4000-z
        let p = vec3(px.float32/100-32, 0.25, pz.float32/100-20)
        rocks.placeProp("rock_medium_0" & $(1+j mod 3) & "a", p, j.float32, 2.2)
        grove.placeProp("ivy_01a", p+vec3(0, 1.5, 0), j.float32, 1.1)
  # Distinct broadleaf silhouettes break up the conifer boundary.
  for i in 0..<6:
    let x = 700+i*1000
    let z = if i mod 2 == 0: minZ()-100 else: maxZ()+100
    grove.placeProp(trees[i], at(x.float32, z.float32), i.float32, 7.5)
  for i in 0..<38:
    let x = 350+(i*157 mod 5600)
    let z = if i mod 2 == 0: 100+(i*31 mod 130) else: 3750+(i*17 mod 100)
    grove.placeProp("flowers_patch_0" & $(1+i mod 3) & "a", at(x.float32,
        z.float32), i.float32, 0.5)

  if wilderness:
    for i,p in [point(-620,300),point(-620,1700),point(-620,3500),point(1200,-320),point(3100,-320),point(5400,-320)]:
      for q in [p,point(6400-p.x.int,4000-p.z.int)]:
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
        grove.placeProp("flowers_patch_0" & $(1+i mod 3) & "a",p+vec3(0.8,0,0.5),i.float32,0.8)

proc placeVillage*(world: World) =
  let homes = loadPropPack(DataRoot & "/terrain/toon_golden_valley/presets.glb",
      unitHeight = false, textured = true, only = @["house_02", "house_03", "bakery"])
  let props = loadPropPack(DataRoot & "/terrain/toon_golden_valley/props.glb",
      unitHeight = false, textured = true, only = @["well_01a",
          "wood_barrel_01a", "wood_crate_01a"])
  let meadow = loadPropPack(DataRoot & "/terrain/toon_enchanted_meadow/props.glb",
      unitHeight = false, textured = true, only = @["wood_cart_01a",
          "flower_pot_01a"])
  let vegetables = loadPropPack(DataRoot & "/terrain/low_poly_village.glb",
      unitHeight = true, textured = true, only = @["carrot1", "tomato1"])
  let greenery = loadPropPack(DataRoot &
      "/terrain/toon_enchanted_meadow/vegetation.glb", unitHeight = true,
      textured = true,
      only = @["flowers_patch_01a", "flowers_patch_02a", "mushroom_01a",
          "mushroom_03a"])
  proc fit(pack: PropPack, name: string, c: Cover, height: float32,
      reversed: bool) =
    let dims = pack.propDimensions(name)
    pack.placeProp(name, vec3((c.x.float32+c.w.float32/2)/100-32, 0,
        (c.z.float32+c.h.float32/2)/100-20),
        if reversed: PI.float32 else: 0'f32, 1, vec3(1, 1, 1),
        vec3(c.w.float32/100/dims.x, height/dims.y, c.h.float32/100/dims.z))
  for i, c in world.cover:
    let kind = if i div 2 < VillageLots.len: VillageLots[
        i div 2].kind else: well
    let reverse = i mod 2 == 1
    case kind
    of cottage:
      fit(homes, if i div 2 mod 2 == 0: "house_02" else: "house_03", c, 5.2, reverse)
    of bakery: fit(homes, "bakery", c, 5.8, reverse)
    of gardenWall:
      # Timber raised beds fill the same solid footprints as the village walls.
      fit(props, "wood_crate_01a", c, 0.7, reverse)
      let alongX = c.w > c.h
      let count = max(c.w, c.h).int div 65
      for n in 0..<count:
        for row in 0..1:
          let along = 35'f32+n.float32*65
          let across = 25'f32+row.float32*40
          let x = c.x.float32+(if alongX: along else: across)
          let z = c.z.float32+(if alongX: across else: along)
          vegetables.placeProp(if i div 2 mod 2 == 0: "carrot1" else: "tomato1",
              vec3(x/100-32, 0.68, z/100-20), 0, 0.7)

    of cart: fit(meadow, "wood_cart_01a", c, 1.8, reverse)
    of supplies:
      # A filled stack keeps the whole rectangular obstacle visibly occupied.
      fit(props, "wood_crate_01a", c, 1.35, reverse)
      let top = Cover(x: c.x+35, z: c.z+35, w: c.w-70, h: c.h-70)
      let dim = props.propDimensions("wood_barrel_01a")
      props.placeProp("wood_barrel_01a", vec3((
          top.x+top.w div 2).float32/100-32, 1.35, (
              top.z+top.h div 2).float32/100-20), 0, 1,
          vec3(1, 1, 1), vec3(top.w.float32/100/dim.x, 0.9/dim.y,
              top.h.float32/100/dim.z))
    of well: fit(props, "well_01a", c, 2.8, false)
  # Outskirts are scenic: these pots sit beyond the arena boundary.
  for x in [-26'f32, -13, 0, 13, 26]:
    for z in [-22'f32, 22]:
      meadow.placeProp("flower_pot_01a", vec3(x, 0, z), 0, 0.7)

  # Low flowers are walkable, like the terrain grass; tall decoration stays outside.
  for side in 0..1:
    for j in 0..<9:
      let x = 13.0'f32 + j.float32 * 0.65
      let z = 10.1'f32
      let p = if side == 0: vec3(x-32, 0, z-20) else: vec3(32-x, 0, 20-z)
      greenery.placeProp(if j mod 2 == 0: "flowers_patch_01a" else: "flowers_patch_02a",
          p, j.float32, 0.35)
    for j in 0..<7:
      let x = -27'f32+j.float32*8
      let z = if side == 0: -21.5'f32 else: 21.5'f32
      greenery.placeProp(if j mod 2 == 0: "mushroom_01a" else: "mushroom_03a",
          vec3(x, 0, z), j.float32, 0.9+0.2*(j mod 3).float32)
