## The GL side of heartleaf houses: loads the kits a house draws from in
## their authored metres, and stands one recipe's pieces on the terrain.
## Shared by the game viewer and the house lab.

import
  vmath,
  polyworld/[common, quadterrain],
  decor,
  houses

const
  TilesPerMeter* = 0.6'f32
    ## The kits are authored a little over life size; this puts a door at
    ## about a villager's height and a three-module cottage inside the
    ## five-tile house pad.

type HousePacks* = array[DecorKit, PropPack]

proc loadHousePacks*(): HousePacks =
  ## Loads every kit the house recipes draw from, textured and unscaled.
  for kit in DecorKit:
    if houseNodesFor(kit).len == 0:
      continue
    result[kit] = loadPropPack(
      DataRoot & "/" & kitFile(kit), unitHeight = false, textured = true,
      only = houseNodesFor(kit))

proc placeHouse*(
    packs: HousePacks, pieces: seq[HousePiece], centre: Vec3, yaw: float32
) =
  ## Adds one house's pieces to the next terrain bake, turned to face
  ## along `yaw` and scaled to tiles.
  let turn = rotateY(yaw)
  for piece in pieces:
    let
      spun = turn * vec3(piece.offset.x, 0, piece.offset.z)
      position = vec3(
        centre.x + spun.x * TilesPerMeter,
        centre.y + piece.offset.y * TilesPerMeter,
        centre.z + spun.z * TilesPerMeter)
    packs[piece.kit].placeProp(
      piece.node, position, yaw + piece.yaw, TilesPerMeter, piece.tint)
