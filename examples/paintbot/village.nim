## Mirrored village cover. Each rectangle is shared by physics and scenery.
## Coordinates are centimetres; paired obstacles face opposite directions.
type VillageKind* = enum
  cottage, bakery, gardenWall, cart, supplies, well
const VillageLots* = [
  (kind: cottage, x: 1250, z: 450, w: 650, h: 480),
  (kind: cottage, x: 1250, z: 2870, w: 650, h: 480),
  (kind: bakery, x: 2400, z: 2650, w: 750, h: 480),
  (kind: gardenWall, x: 2050, z: 1200, w: 450, h: 90),
  (kind: gardenWall, x: 2050, z: 1290, w: 90, h: 350),
  (kind: cart, x: 1200, z: 1850, w: 340, h: 210),
  (kind: supplies, x: 2720, z: 1830, w: 170, h: 180),
]
