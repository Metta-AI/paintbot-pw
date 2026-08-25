## Gods of the Arena map: lane paths must keep the mid-lane bridge.

import
  polyworld/pathing,
  ../examples/gods_of_the_arena/maps

const MidLane = [
  (GroundLayer, 23, 21), (GroundLayer, 29, 21),
  (GroundLayer, 48, 54), (BridgeLayer, 11, 3),
  (GroundLayer, 82, 68), (GroundLayer, 98, 106),
  (GroundLayer, 104, 106)
]

echo "Testing the mid lane keeps the bridge after string-pull"
block:
  discard generateMap(2026)
  var tiles: seq[PathTile]
  for i in 0 ..< MidLane.len - 1:
    let
      a = MidLane[i]
      b = MidLane[i + 1]
      segment = findTilePath(a[0], a[1], a[2], b[0], b[1], b[2])
    doAssert segment.len > 0, "each mid-lane stop must be reachable"
    for tileIndex, tile in segment:
      if tiles.len > 0 and tileIndex == 0:
        continue
      tiles.add tile
  var rawLayers: set[uint8]
  for tile in tiles:
    rawLayers.incl uint8(tile.layer)
  doAssert 1'u8 in rawLayers, "the unsmoothed mid lane must use the deck"
  let pulled = smoothPathTiles(tiles)
  var pulledLayers: set[uint8]
  for tile in pulled:
    pulledLayers.incl uint8(tile.layer)
  doAssert 1'u8 in pulledLayers,
    "creeps follow the pulled lane, so the deck waypoint must remain"

echo "GOTA world tests passed"
