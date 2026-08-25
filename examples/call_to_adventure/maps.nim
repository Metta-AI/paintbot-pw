## Call to Adventure map generation.
##
## Builds the six dungeon levels from an explicit seed using only integers.
## Writes `pathing.layers` once and returns a `Dungeon`, which is this
## game's map data. The simulation never writes terrain. Graphics may
## sample `surfaceHeight` and must not write simulation state.
##
## Every level is one slab `QuadLayer` on the shared 128x128 grid at its
## own height band. Floors do not fill that grid: rooms snake through it
## with long halls and empty dead space, and each level starts offset from
## the one above so the stack looks skewed. Walking up a ramp is an
## ordinary step that happens to land on another layer.
##
## Two rules keep that safe. Levels sit 64 height steps apart while walls
## rise only about a character, so no two levels can ever share a corner
## height by accident. `computeEdgeLink` matches purely on corner equality
## and takes the first layer that agrees, so overlapping bands would
## produce silent teleports. Every height here is written as an `int16`
## step count; interpolating a ramp in float and rounding is exactly how
## a mouth ends up an eighth of a tile short, which leaves the tile
## walkable but never linked.

import
  polyworld/[hashes, pathing, profiles, rngs],
  content

## Materials

const
  FloorTile* = 6'u32
  RubbleTile* = 7'u32
  LavaTile* = 8'u32
  ObsidianTile* = 9'u32
  GoldTile* = 10'u32
  MossTile* = 11'u32
  RampTile* = 12'u32

## Height bands

const
  BandSteps* = 64'i16          ## 8 tiles between levels
  RampRise* = 8'i16            ## height steps gained per ramp tile, so 45 deg
  RampLength* = int(BandSteps div RampRise)
  WallSteps* = 12'i16          ## apron and pillar height, about a character
  SlabSteps* = 24'i16          ## floor thickness, the visible slab
  SurfaceBase* = 0'i16

proc levelBase*(level: int): int16 =
  ## Floor height of one level in 1/8-tile steps.
  SurfaceBase - BandSteps * int16(level)

## Level themes

type LevelTheme* = object
  floorKind*: uint32
  wallKind*: uint32
  name*: string

const Themes*: array[LevelCount, LevelTheme] = [
  LevelTheme(floorKind: GrassTile, wallKind: RockTile, name: "Surface"),
  LevelTheme(floorKind: FloorTile, wallKind: StoneTile, name: "Old Halls"),
  LevelTheme(floorKind: RubbleTile, wallKind: RockTile, name: "Caves"),
  LevelTheme(floorKind: MossTile, wallKind: RockTile, name: "Flooded Deep"),
  LevelTheme(floorKind: ObsidianTile, wallKind: LavaTile, name: "Lava Hall"),
  LevelTheme(floorKind: GoldTile, wallKind: StoneTile, name: "Vault")
]

## Rooms

type
  RoomKind* = enum
    RectRoom, PillarRoom

  Room* = object
    x*, z*, width*, depth*: int32
    kind*: RoomKind

  RampLink* = object
    ## One authored connection between two levels, kept so the world can
    ## assert afterwards that no *other* cross-layer link exists.
    upper*, lower*: int32
    topX*, topZ*: int32        ## landing tile on the upper level
    bottomX*, bottomZ*: int32  ## landing tile on the lower level

  StairSite* = object
    x*, z*: int32      ## x is the shaft centre, z the top landing row

  Dungeon* = object
    seed*: int32
    hash*: uint64
    rooms*: array[LevelCount, seq[Room]]
    ramps*: seq[RampLink]
    entrance*: TileRef         ## where the party starts, on the surface
    vault*: TileRef            ## the deepest room's centre

  MapData* = Dungeon

proc center*(room: Room): (int32, int32) =
  (room.x + room.width div 2, room.z + room.depth div 2)

proc contains*(room: Room, x, z: int32): bool =
  x >= room.x and x < room.x + room.width and
    z >= room.z and z < room.z + room.depth

## Tile writing

var
  levelLayers: array[LevelCount, QuadLayer]
  openShaft: array[LevelCount, seq[bool]]
    ## Tiles deliberately absent so a stairwell is a real hole in the floor
    ## rather than a slope clipping through it. Nothing may write these back:
    ## the apron pass in particular would otherwise wall the shaft up again,
    ## because from its point of view a hole is simply an uncarved tile next
    ## to a carved one.
  rampLocked: array[LevelCount, seq[bool]]
    ## Sloped ramp tiles, which later carving must leave alone. A corridor
    ## routed north from an arrival chamber will happily run up the ramp and
    ## flatten one of its steps, and the result is a stair that looks perfect
    ## and silently no longer links, because two adjacent steps stop sharing
    ## a corner height.

proc tileAt(level: int, x, z: int32): var Tile =
  levelLayers[level].tiles[z * GridTiles + x]

proc inBounds(x, z: int32): bool =
  x >= 1 and x < GridTiles - 1 and z >= 1 and z < GridTiles - 1

proc shaftOpen(level: int, x, z: int32): bool =
  inBounds(x, z) and openShaft[level][z * GridTiles + x]

proc frozen(level: int, x, z: int32): bool =
  ## True where generation has already placed something that must survive.
  inBounds(x, z) and
    (openShaft[level][z * GridTiles + x] or
      rampLocked[level][z * GridTiles + x])

proc openTheShaft(level: int, x, z: int32) =
  ## Removes a tile and keeps it removed.
  if not inBounds(x, z):
    return
  tileAt(level, x, z) = Tile()
  openShaft[level][z * GridTiles + x] = true

proc carve(level: int, x, z: int32, height: int16, kind: uint32) =
  ## Writes one flat walkable tile. All four corners get the same height, so
  ## any two carved tiles at the same height in the same level link without
  ## further thought — that property is what makes connectivity provable.
  if not inBounds(x, z) or frozen(level, x, z):
    return
  tileAt(level, x, z) = Tile(
    tops: [height, height, height, height],
    bottoms: [
      height - SlabSteps, height - SlabSteps,
      height - SlabSteps, height - SlabSteps
    ],
    flags: TileExists or TileConnectedEast or TileConnectedSouth,
    kind: kind
  )

proc wall(
    level: int,
    x, z: int32,
    floor: int16,
    kind: uint32,
    overwrite = true
) =
  ## Writes one solid impassable block about a character tall.
  if not inBounds(x, z) or frozen(level, x, z):
    return
  if not overwrite and tileAt(level, x, z).exists:
    return
  let top = floor + WallSteps
  tileAt(level, x, z) = Tile(
    tops: [top, top, top, top],
    bottoms: [
      floor - SlabSteps, floor - SlabSteps,
      floor - SlabSteps, floor - SlabSteps
    ],
    flags: TileExists or TileImpassable,
    kind: kind
  )

proc carved(level: int, x, z: int32): bool =
  if not inBounds(x, z):
    return false
  let tile = tileAt(level, x, z)
  tile.exists and not tile.impassable

## Room layout

const
  RoomGap = 2'i32
  HallMin = 8'i32
  HallMax = 18'i32
  SideHallMin = 6'i32
  SideHallMax = 12'i32
  SpineRooms = 5'i32
  ShaftHalfWidth* = 2'i32                    ## the hole is 5 tiles across
  ShaftRows* = int32(RampLength) + 1         ## slope plus the row it lands on
  StairRoomWidth* = ShaftHalfWidth * 2 + 5   ## floor left to walk around it
  StairRoomDepth* = ShaftRows + 4

proc fitsStairs*(room: Room): bool =
  ## True when a stairwell can sit in this room with floor left around it.
  room.width >= StairRoomWidth and room.depth >= StairRoomDepth

proc playArea(level: int): Room =
  ## A shifted rectangle inside the grid. Each floor slides so stacked
  ## slabs do not sit on the same footprint.
  Room(
    x: 8'i32 + int32((level * 7) mod 16),
    z: 8'i32 + int32((level * 11) mod 14),
    width: 100,
    depth: 100
  )

proc overlaps(a, b: Room, gap: int32): bool =
  ## True when two rooms sit closer than `gap` tiles.
  not (
    a.x + a.width + gap <= b.x or
    b.x + b.width + gap <= a.x or
    a.z + a.depth + gap <= b.z or
    b.z + b.depth + gap <= a.z
  )

proc insideArea(area, room: Room): bool =
  ## True when `room` sits fully inside `area` and the grid margin.
  room.x >= area.x and room.z >= area.z and
    room.x + room.width <= area.x + area.width and
    room.z + room.depth <= area.z + area.depth and
    inBounds(room.x, room.z) and
    inBounds(room.x + room.width - 1, room.z + room.depth - 1)

proc roomFits(area: Room, rooms: seq[Room], room: Room): bool =
  ## True when `room` is in bounds and does not overlap `rooms`.
  if not insideArea(area, room):
    return false
  for other in rooms:
    if overlaps(room, other, RoomGap):
      return false
  true

proc roomFrom(
    prev: Room,
    heading, hall, w, d, stagger: int32
): Room =
  ## Places a room a hallway away from `prev` in one cardinal direction.
  case heading
  of 0:
    Room(
      x: prev.x + prev.width + hall,
      z: prev.z + stagger,
      width: w, depth: d
    )
  of 1:
    Room(
      x: prev.x + stagger,
      z: prev.z + prev.depth + hall,
      width: w, depth: d
    )
  of 2:
    Room(
      x: prev.x - hall - w,
      z: prev.z + stagger,
      width: w, depth: d
    )
  else:
    Room(
      x: prev.x + stagger,
      z: prev.z - hall - d,
      width: w, depth: d
    )

proc turnHeading(heading, turn: int32): int32 =
  ## Turns left (`turn` 3), right (`turn` 1), or around (`turn` 2).
  (heading + turn) and 3

proc pickKind(rng: var Rng, w, d: int32, pillar: bool): RoomKind =
  ## Picks a pillared hall or a plain room from size and a roll.
  if w >= 12 and d >= 12 and (pillar or rng.chance(40)):
    return PillarRoom
  RectRoom

proc tryPlace(
    area: Room,
    blocked: seq[Room],
    prev: Room,
    heading, hall, w, d: int32,
    rng: var Rng
): (bool, Room) =
  ## Tries a few staggers along `heading` and returns the first that fits.
  for _ in 0 ..< 4:
    let
      stagger = rng.between(-3, 3)
      room = roomFrom(prev, heading, hall, w, d, stagger)
    if roomFits(area, blocked, room):
      return (true, room)
  (false, Room())

proc layoutSnake(
    rng: var Rng,
    area: Room,
    fromX, fromZ: int32,
    startHeading: int32,
    rooms: var seq[Room],
    links: var seq[(int32, int32)]
): bool =
  ## Walks a spine of rooms away from the arrival tile, then hangs a few
  ## dead-end side rooms off it. Returns false when the floor cannot hold
  ## a stair hall.
  rooms.setLen(0)
  links.setLen(0)
  var blocked = @[Room(
    x: fromX - 4,
    z: fromZ - int32(RampLength) - 1,
    width: 9,
    depth: int32(RampLength) + 6
  )]
  let origin = Room(x: fromX, z: fromZ, width: 1, depth: 1)
  var heading = startHeading
  var prev = origin
  var prevIndex = -1'i32
  for i in 0 ..< SpineRooms:
    let
      stair = i == SpineRooms - 1
      hall =
        if i == 0: rng.between(14, 22)
        else: rng.between(HallMin, HallMax)
    var
      w = rng.between(8, 14)
      d = rng.between(8, 14)
    if stair:
      w = max(w, StairRoomWidth + 2)
      d = max(d, StairRoomDepth + 2)
    elif rng.chance(30):
      if rng.chance(50):
        w = rng.between(14, 18)
      else:
        d = rng.between(14, 18)
    var
      placed = false
      room = Room()
      used = heading
    for turn in [0'i32, 1, 3, 2]:
      used = turnHeading(heading, turn)
      let (ok, candidate) = tryPlace(
        area, blocked, prev, used, hall, w, d, rng
      )
      if ok:
        placed = true
        room = candidate
        heading = used
        break
    if not placed:
      return false
    room.kind = pickKind(rng, room.width, room.depth, stair)
    rooms.add room
    blocked.add room
    if prevIndex >= 0:
      links.add (prevIndex, int32(rooms.high))
    prevIndex = int32(rooms.high)
    prev = room
  var sides = 0'i32
  for parent in 0 ..< rooms.len:
    if sides >= 2:
      break
    if not rng.chance(40):
      continue
    let
      sideHeading = turnHeading(startHeading, if rng.chance(50): 1 else: 3)
      hall = rng.between(SideHallMin, SideHallMax)
      w = rng.between(8, 11)
      d = rng.between(8, 11)
    let (ok, room) = tryPlace(
      area, blocked, rooms[parent], sideHeading, hall, w, d, rng
    )
    if not ok:
      continue
    var placed = room
    placed.kind = pickKind(rng, placed.width, placed.depth, false)
    rooms.add placed
    blocked.add placed
    links.add (int32(parent), int32(rooms.high))
    inc sides
  for room in rooms:
    if room.fitsStairs:
      return true
  false

proc carveRoom(level: int, room: Room, height: int16, kind: uint32) =
  ## Fills a room's rectangle with flat floor tiles.
  for z in room.z ..< room.z + room.depth:
    for x in room.x ..< room.x + room.width:
      carve(level, x, z, height, kind)

proc carveCorridor(
    level: int,
    fromX, fromZ, toX, toZ: int32,
    height: int16,
    kind: uint32,
    width: int32
) =
  ## An L-shaped run, horizontal leg first. Carved at the level's own floor
  ## height like everything else, so it links to both rooms by construction.
  let
    start = -(width div 2)
    stop = start + width - 1
  var x = fromX
  while x != toX:
    for offset in start .. stop:
      carve(level, x, fromZ + offset, height, kind)
    x += (if toX > x: 1 else: -1)
  var z = fromZ
  while z != toZ:
    for offset in start .. stop:
      carve(level, toX + offset, z, height, kind)
    z += (if toZ > z: 1 else: -1)
  for offset in start .. stop:
    carve(level, toX + offset, toZ, height, kind)

proc nearShaft(level: int, x, z: int32): bool =
  ## True when a stairwell hole sits within two tiles.
  for dz in -2'i32 .. 2'i32:
    for dx in -2'i32 .. 2'i32:
      if shaftOpen(level, x + dx, z + dz):
        return true
  false

proc placePillars(
    level: int,
    room: Room,
    height: int16,
    kind: uint32
) =
  ## Two rows of columns along the long axis, leaving a centre aisle.
  if room.kind != PillarRoom:
    return
  if room.width < 12 or room.depth < 12:
    return
  let alongX = room.width >= room.depth
  if alongX:
    let
      span = room.width - 4
      count = min(6'i32, max(3'i32, span div 3))
      row0 = room.z + room.depth div 3
      row1 = room.z + (room.depth * 2) div 3
    for i in 0 ..< count:
      let x =
        if count == 1: room.x + room.width div 2
        else: room.x + 2 + i * span div (count - 1)
      if carved(level, x, row0) and not nearShaft(level, x, row0):
        wall(level, x, row0, height, kind)
      if carved(level, x, row1) and not nearShaft(level, x, row1):
        wall(level, x, row1, height, kind)
  else:
    let
      span = room.depth - 4
      count = min(6'i32, max(3'i32, span div 3))
      col0 = room.x + room.width div 3
      col1 = room.x + (room.width * 2) div 3
    for i in 0 ..< count:
      let z =
        if count == 1: room.z + room.depth div 2
        else: room.z + 2 + i * span div (count - 1)
      if carved(level, col0, z) and not nearShaft(level, col0, z):
        wall(level, col0, z, height, kind)
      if carved(level, col1, z) and not nearShaft(level, col1, z):
        wall(level, col1, z, height, kind)

## Stairwells

# Each descent gets its own site, chosen per level and placed as far as
# possible from wherever the party arrived on that level. A single shared
# stair column let a party drop straight to the bottom without exploring
# anything; now the way down has to be found.

proc stairSiteIn*(room: Room): StairSite =
  ## Centres the shaft in a room so floor is left on every side of it. The
  ## party walks around the hole, which is what stops a stairwell from
  ## cutting in half the room it sits in.
  StairSite(
    x: room.x + room.width div 2,
    z: room.z + (room.depth - ShaftRows) div 2
  )

proc chooseStairRoom*(rooms: seq[Room], arrivalX, arrivalZ: int32): int =
  ## The room that can hold a stairwell and lies furthest from where the
  ## party enters this level, so going down means crossing the floor rather
  ## than stepping off one stair straight onto the next.
  result = -1
  var best = -1'i64
  for index, room in rooms:
    if not room.fitsStairs:
      continue
    let
      (cx, cz) = room.center
      dx = int64(cx - arrivalX)
      dz = int64(cz - arrivalZ)
      distance = dx * dx + dz * dz
    if distance > best:
      best = distance
      result = index

proc carveRamp(
    dungeon: var Dungeon,
    upper, lower: int,
    site: StairSite
): bool =
  ## Cuts the ramp descending south from the upper level into the lower one.
  ## Every corner is integer arithmetic on the two band heights, so the
  ## mouths match their landings exactly: an eighth of a tile out and the
  ## tiles stay walkable but never link.
  let
    high = levelBase(upper)
    low = levelBase(lower)
    x = site.x
    z = site.z
  doAssert (high - low) == BandSteps
  doAssert BandSteps mod RampRise == 0

  let
    rampStartZ = z + 1
    rampEndZ = rampStartZ + int32(RampLength)
  if not inBounds(x - ShaftHalfWidth, z - 1) or
      not inBounds(x + ShaftHalfWidth, rampEndZ + 3):
    return false

  # The landing you step off from, forced flat at the upper band height.
  for lane in -ShaftHalfWidth .. ShaftHalfWidth:
    carve(upper, x + lane, z, high, RampTile)

  # Open the floor over the slope, and keep it open. Without this the apron
  # pass walls the stairwell straight back up, because a hole looks exactly
  # like an uncarved tile beside a carved one, and the ramp ends up buried
  # under the floor it descends from.
  for step in 0'i32 ..< ShaftRows:
    for lane in -ShaftHalfWidth .. ShaftHalfWidth:
      openTheShaft(upper, x + lane, rampStartZ + step)

  # The slope itself, three lanes wide, belonging to the lower level.
  for step in 0 ..< int32(RampLength):
    let
      near = high - RampRise * int16(step)
      far = high - RampRise * int16(step + 1)
      tz = rampStartZ + step
    for lane in -1'i32 .. 1'i32:
      if not inBounds(x + lane, tz):
        return false
      tileAt(lower, x + lane, tz) = Tile(
        tops: [near, near, far, far],
        bottoms: [
          near - SlabSteps, near - SlabSteps,
          far - SlabSteps, far - SlabSteps
        ],
        flags: TileExists or TileConnectedEast or TileConnectedSouth,
        kind: RampTile
      )
      rampLocked[lower][tz * GridTiles + (x + lane)] = true

  # Arrival chamber at the bottom, flat at the lower band height.
  for lane in -ShaftHalfWidth .. ShaftHalfWidth:
    for row in 0'i32 .. 3'i32:
      carve(lower, x + lane, rampEndZ + row, low, RampTile)

  dungeon.ramps.add RampLink(
    upper: int32(upper),
    lower: int32(lower),
    topX: x,
    topZ: z,
    bottomX: x,
    bottomZ: rampEndZ
  )
  true

## Connectivity

proc floodFill(level: int, startX, startZ: int32): seq[bool] =
  ## Reachability over the engine's own edge links, restricted to one level,
  ## so the generator and the pathfinder can never disagree about what is
  ## connected.
  result = newSeq[bool](GridTiles * GridTiles)
  if not isWalkable(level, startX, startZ):
    return
  var stack = @[(startX, startZ)]
  result[startZ * GridTiles + startX] = true
  while stack.len > 0:
    let (x, z) = stack.pop()
    for direction in 0 .. 3:
      let link = edgeLink(level, int(x), int(z), direction)
      if not link.open or link.layer != level:
        continue
      let index = link.z * GridTiles + link.x
      if not result[index]:
        result[index] = true
        stack.add (int32(link.x), int32(link.z))

proc connectRooms(
    dungeon: var Dungeon,
    level: int,
    links: seq[(int32, int32)],
    height: int16,
    theme: LevelTheme
) =
  ## Carves one hall per authored link, so a floor is a snake with optional
  ## dead-end rooms rather than a packed mesh.
  let rooms = dungeon.rooms[level]
  for (a, b) in links:
    let
      (ax, az) = rooms[a].center
      (bx, bz) = rooms[b].center
    carveCorridor(level, ax, az, bx, bz, height, theme.floorKind, 3)

proc buildApron(level: int, height: int16, theme: LevelTheme) =
  ## Surrounds the carved space with a thin ring of rock so the level reads
  ## as an interior and nothing can walk off its edge. Empty tiles beyond
  ## that ring stay absent, which is the dead space between halls.
  var solid: seq[(int32, int32)]
  for z in 0'i32 ..< GridTiles:
    for x in 0'i32 ..< GridTiles:
      if tileAt(level, x, z).exists:
        continue
      var touching = false
      for dz in -1'i32 .. 1'i32:
        for dx in -1'i32 .. 1'i32:
          if carved(level, x + dx, z + dz):
            touching = true
      if touching:
        solid.add (x, z)
  for (x, z) in solid:
    wall(level, x, z, height, theme.wallKind, overwrite = false)

## Level generation

proc walkableIn*(dungeon: Dungeon, level: int, room: Room): (int32, int32) =
  ## A walkable tile inside a room, spiralling out from its centre, or
  ## (-1, -1) when the room has no floor left at all.
  let (cx, cz) = room.center
  if isWalkable(level, cx, cz):
    return (cx, cz)
  for radius in 1'i32 .. max(room.width, room.depth):
    for dz in -radius .. radius:
      for dx in -radius .. radius:
        let
          x = cx + dx
          z = cz + dz
        if room.contains(x, z) and isWalkable(level, x, z):
          return (x, z)
  (-1'i32, -1'i32)

proc generateLevel(
    dungeon: var Dungeon,
    rng: var Rng,
    level: int,
    fromX, fromZ: int32,
    links: var seq[(int32, int32)]
) =
  ## Places and carves one floor. Dungeon levels snake away from `fromX`,
  ## `fromZ`. The surface is a single clearing.
  let
    height = levelBase(level)
    theme = Themes[level]
    area = playArea(level)
  var rooms: seq[Room]
  if level == 0:
    rooms.add Room(
      x: area.x + 36, z: area.z + 4,
      width: 24, depth: 42, kind: RectRoom
    )
  else:
    let startHeading = int32(level + 3) and 3
    var placed = false
    for attempt in 0 ..< 16:
      if layoutSnake(
          rng, area, fromX, fromZ, startHeading, rooms, links):
        placed = true
        break
    doAssert placed,
      "no snake on level " & $level & " can hold a stairwell"
  dungeon.rooms[level] = rooms
  for room in rooms:
    carveRoom(level, room, height, theme.floorKind)
  dungeon.connectRooms(level, links, height, theme)

proc decorateLevel(dungeon: Dungeon, level: int) =
  ## Adds interior columns after halls are already carved.
  let
    height = levelBase(level)
    theme = Themes[level]
  for room in dungeon.rooms[level]:
    placePillars(level, room, height, theme.wallKind)

proc terrainHash*(): uint64

proc generateDungeon(seed: int32): Dungeon {.measure.} =
  ## Builds all six levels, joins them with ramps, and asserts the result is
  ## actually traversable before anyone tries to walk it.
  var rng = initRng(seed)

  for level in 0 ..< LevelCount:
    levelLayers[level] = QuadLayer(
      originX: 0,
      originZ: 0,
      width: GridTiles,
      depth: GridTiles,
      slab: true,
      tiles: newSeq[Tile](GridTiles * GridTiles)
    )

  for level in 0 ..< LevelCount:
    openShaft[level] = newSeq[bool](GridTiles * GridTiles)
    rampLocked[level] = newSeq[bool](GridTiles * GridTiles)

  var roomLinks: array[LevelCount, seq[(int32, int32)]]
  result.generateLevel(rng, 0, 0, 0, roomLinks[0])

  layers = @[]
  for level in 0 ..< LevelCount:
    layers.add levelLayers[level]

  var
    arrivalX = int32(GridTiles div 2)
    arrivalZ = int32(GridTiles div 2)
  block:
    # The party starts at the clearing's north edge and the stairwell
    # sits far south of them, so even the first descent is a walk.
    let clearing = result.rooms[0][0]
    arrivalX = clearing.x + clearing.width div 2
    arrivalZ = clearing.z + 3
  result.entrance = TileRef(
    level: 0, x: uint8(arrivalX), z: uint8(arrivalZ))

  for level in 0 ..< LevelCount - 1:
    let
      rooms = result.rooms[level]
      chosen = chooseStairRoom(rooms, arrivalX, arrivalZ)
    doAssert chosen >= 0,
      "no room on level " & $level & " can hold a stairwell"
    let site = stairSiteIn(rooms[chosen])
    doAssert result.carveRamp(level, level + 1, site),
      "the stairwell on level " & $level & " does not fit"

    # The lower snake starts a long hall away from this landing, so the
    # party walks off the back of one floor onto the front of the next.
    let
      landingZ = site.z + 1 + int32(RampLength)
      landingX = site.x
    result.generateLevel(
      rng, level + 1, landingX, landingZ, roomLinks[level + 1]
    )
    arrivalX = landingX
    arrivalZ = landingZ

  for level in 0 ..< LevelCount:
    result.decorateLevel(level)
    # Halls are recarved after pillars so a column never isolates a room.
    result.connectRooms(
      level, roomLinks[level], levelBase(level), Themes[level]
    )
    for ramp in result.ramps:
      if int(ramp.lower) != level:
        continue
      let below = result.rooms[level]
      var nearest = 0
      var bestDistance = int64.high
      for index, room in below:
        let
          (cx, cz) = room.center
          dx = int64(cx - ramp.bottomX)
          dz = int64(cz - ramp.bottomZ)
          distance = dx * dx + dz * dz
        if distance < bestDistance:
          bestDistance = distance
          nearest = index
      let (nx, nz) = below[nearest].center
      carveCorridor(
        level, ramp.bottomX, ramp.bottomZ + 2, nx, nz,
        levelBase(level), Themes[level].floorKind, 3
      )
    buildApron(level, levelBase(level), Themes[level])

  # The engine's walkability limit is a fixed 55 degrees. Ramps rise one
  # eighth of a tile per eighth of a tile travelled, which is 45 degrees, so
  # they stay walkable while the vertical aprons never do.
  computeWalkable()

  # The entrance was fixed before the stairs were cut; make sure the tile is
  # still floor, since the surface stairwell may have opened where it stood.
  if not isWalkable(
      int(result.entrance.level),
      int(result.entrance.x),
      int(result.entrance.z)):
    let (fx, fz) = result.walkableIn(0, result.rooms[0][0])
    doAssert fx >= 0, "the surface clearing has no floor left"
    result.entrance = TileRef(level: 0, x: uint8(fx), z: uint8(fz))

  # The vault is the deepest arrival, so the party has to walk the last floor
  # rather than dropping straight onto the hoard.
  let deepest = LevelCount - 1
  var
    vaultRoom = 0
    bestDistance = -1'i64
  let landing = result.ramps[^1]
  for index, room in result.rooms[deepest]:
    let
      (cx, cz) = room.center
      dx = int64(cx - landing.bottomX)
      dz = int64(cz - landing.bottomZ)
      distance = dx * dx + dz * dz
    if distance > bestDistance:
      bestDistance = distance
      vaultRoom = index
  let (vx, vz) = result.walkableIn(deepest, result.rooms[deepest][vaultRoom])
  doAssert vx >= 0, "the vault room has no floor"
  result.vault = TileRef(level: int8(deepest), x: uint8(vx), z: uint8(vz))
  result.seed = seed
  result.hash = terrainHash()

proc generateMap*(seed: int32): MapData =
  ## Builds the dungeon for one expedition seed.
  generateDungeon(seed)

proc terrainHash*(): uint64 =
  ## Fingerprints every generated tile and walkability decision.
  var hash = HashySeed
  hash.addHashy(layers.len)
  for layerIndex, layer in layers:
    hash.addHashy(layer.originX)
    hash.addHashy(layer.originZ)
    hash.addHashy(layer.width)
    hash.addHashy(layer.depth)
    hash.addHashy(layer.slab)
    for index, tile in layer.tiles:
      hash.addHashy(uint32(tile.flags))
      hash.addHashy(uint32(tile.kind))
      for value in tile.tops:
        hash.addHashy(value)
      for value in tile.bottoms:
        hash.addHashy(value)
      hash.addHashy(layerWalkable[layerIndex][index])
  uint64(hash)

## Assertions

proc verifyDungeon*(dungeon: Dungeon) =
  ## The checks that make six stacked levels safe to walk.
  for ramp in dungeon.ramps:
    let down = edgeLink(
      int(ramp.upper), int(ramp.topX), int(ramp.topZ), South.ord)
    doAssert down.open,
      "ramp from level " & $ramp.upper & " does not link at the top"
    doAssert down.layer == int(ramp.lower),
      "ramp top links to layer " & $down.layer & ", expected " & $ramp.lower

  # No cross-layer link may exist that is not part of an authored ramp. This
  # is the assertion that catches two levels accidentally sharing a corner
  # height, which would otherwise show up as a teleport in the middle of a
  # fight.
  var strays = 0
  for level in 0 ..< LevelCount:
    for z in 0 ..< GridTiles:
      for x in 0 ..< GridTiles:
        if not isWalkable(level, x, z):
          continue
        for direction in 0 .. 3:
          let link = edgeLink(level, x, z, direction)
          if link.open and link.layer != level:
            inc strays
  doAssert strays > 0, "the levels are not connected to each other at all"

  # Every level's rooms must be mutually reachable within that level, and the
  # stairs must be reachable from them. Probing a room's raw centre is wrong:
  # a shaft or an apron can legitimately occupy it, so ask each room for a
  # tile that is actually walkable and fail loudly if it has none.
  for level in 0 ..< LevelCount:
    let rooms = dungeon.rooms[level]
    if rooms.len == 0:
      continue
    let (sx, sz) = dungeon.walkableIn(level, rooms[0])
    doAssert sx >= 0, "the first room on level " & $level & " has no floor"
    let reached = floodFill(level, sx, sz)
    for index, room in rooms:
      let (rx, rz) = dungeon.walkableIn(level, room)
      doAssert rx >= 0,
        "room " & $index & " on level " & $level & " has no floor"
      doAssert reached[rz * GridTiles + rx],
        "room " & $index & " on level " & $level & " is cut off"
    for ramp in dungeon.ramps:
      if int(ramp.upper) == level:
        doAssert reached[ramp.topZ * GridTiles + ramp.topX],
          "the way down from level " & $level & " is cut off from its rooms"
      if int(ramp.lower) == level:
        doAssert reached[ramp.bottomZ * GridTiles + ramp.bottomX],
          "the way up from level " & $level & " is cut off from its rooms"

proc descentPath*(dungeon: Dungeon): bool =
  ## True when the vault can actually be walked to from the entrance, and
  ## walked back out again.
  let
    entrance = dungeon.entrance
    vault = dungeon.vault
    down = findTilePath(
      int(entrance.level), int(entrance.x), int(entrance.z),
      int(vault.level), int(vault.x), int(vault.z))
    up = findTilePath(
      int(vault.level), int(vault.x), int(vault.z),
      int(entrance.level), int(entrance.x), int(entrance.z))
  down.len > 0 and up.len > 0
