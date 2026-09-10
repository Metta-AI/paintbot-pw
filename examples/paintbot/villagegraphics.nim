## Heartleaf's Golden Valley and Enchanted Meadow art, fitted to solid lots.
import std/math
import vmath
import polyworld/[common, quadterrain]
import sim, village

proc placeVillage*(world: World) =
  let homes = loadPropPack(DataRoot & "/terrain/toon_golden_valley/presets.glb",
      unitHeight = false, textured = true, only = @["house_02", "house_03", "bakery"])
  let props = loadPropPack(DataRoot & "/terrain/toon_golden_valley/props.glb",
      unitHeight = false, textured = true, only = @["well_01a",
          "wood_barrel_01a", "wood_crate_01a"])
  let meadow = loadPropPack(DataRoot & "/terrain/toon_enchanted_meadow/props.glb",
      unitHeight = false, textured = true, only = @["wood_cart_01a",
          "flower_pot_01a"])
  let masonry = loadPropPack(DataRoot & "/terrain/toon_enchanted_meadow/buildings.glb",
      unitHeight = false, textured = true, only = @["stone_wall_01a"])
  let greenery = loadPropPack(DataRoot &
      "/terrain/toon_enchanted_meadow/vegetation.glb", unitHeight = true, textured = true,
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
    of gardenWall: fit(masonry, "stone_wall_01a", c, 1.6, reverse)
    of cart: fit(meadow, "wood_cart_01a", c, 1.8, reverse)
    of supplies:
      # A filled stack keeps the whole rectangular obstacle visibly occupied.
      fit(props, "wood_crate_01a", c, 1.35, reverse)
      let top = Cover(x: c.x+35, z: c.z+35, w: c.w-70, h: c.h-70)
      let dim = props.propDimensions("wood_barrel_01a")
      props.placeProp("wood_barrel_01a", vec3((
          top.x+top.w div 2).float32/100-32, 1.35, (top.z+top.h div 2).float32/100-20),
              0, 1,
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
