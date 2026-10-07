## Procedural maps from coworld/paintbot/tools/mapgen, compiled into the engine and viewer.
## A map replaces the rules-derived island: its terrain grid answers terrainHeight and
## islandMargin, and its hearts, pickups, trenches and cover replace the fixed layout. Every
## map is its own image under the rules-35 half turn about (3200, 2000).
const MapNames* = ["twin-mesas", "archipelago", "serpent-river", "crater", "terraces",
  "deep-forest", "badlands", "atoll", "highlands", "delta",
  # Ten times the area (mapgen --scale 3.1623 --prefix big-): the same layouts, stretched.
  "big-twin-mesas", "big-deep-forest"]

const MapBlobs = block:
  var blobs: array[MapNames.len, string]
  for i, name in MapNames: blobs[i] = staticRead("maps/" & name & ".pbmap")
  blobs

type
  MapCoverKind* = enum mapTree, mapHouse, mapProp, mapRock
  PaintbotMap* = object
    name*: string
    nx*, nz*, x0*, z0*, step*: int
    home*: tuple[x, z: int]
    heights*, margins*: seq[int16]
    hearts*: seq[tuple[x, z, owner: int]]
    pickups*: seq[tuple[x, z, kind: int]] # kind is sim.nim's PickupKind order
    trenches*: seq[tuple[x, z, w, h: int]] # top-left corner and size
    cover*: seq[tuple[x, z, w: int, kind: MapCoverKind]] # round: top-left corner and diameter
    # Per grid cell (i, j) (i < nx-1, j < nz-1, index j*(nx-1)+i): the highest height and the
    # lowest margin of the four grid points sampleGrid interpolates between there. Bilinear
    # weights are non-negative and sum to step^2, and the division truncates an integer bound
    # past no integer, so every height (margin) sampled in the cell is <= (>=) its bound.
    cellMaxHeight*, cellMinMargin*: seq[int16]

proc parseMap(name, blob: string): PaintbotMap =
  doAssert blob.len >= 52 and blob[0..7] == "PBMAP001", "bad map " & name
  var at = 8
  proc i32(): int =
    result = int(cast[int32](uint32(blob[at].uint8) or (uint32(blob[at+1].uint8) shl 8) or
      (uint32(blob[at+2].uint8) shl 16) or (uint32(blob[at+3].uint8) shl 24)))
    at += 4
  proc i16(): int16 =
    result = cast[int16](uint16(blob[at].uint8) or (uint16(blob[at+1].uint8) shl 8))
    at += 2
  result.name = name
  result.nx = i32(); result.nz = i32(); result.x0 = i32(); result.z0 = i32(); result.step = i32()
  result.home = (i32(), i32())
  let counts = [i32(), i32(), i32(), i32()]
  let cells = result.nx*result.nz
  result.heights = newSeq[int16](cells)
  for k in 0..<cells: result.heights[k] = i16()
  result.margins = newSeq[int16](cells)
  for k in 0..<cells: result.margins[k] = i16()
  for k in 0..<counts[0]: result.hearts.add (i32(), i32(), i32())
  for k in 0..<counts[1]: result.pickups.add (i32(), i32(), i32())
  for k in 0..<counts[2]: result.trenches.add (i32(), i32(), i32(), i32())
  for k in 0..<counts[3]: result.cover.add (i32(), i32(), i32(), MapCoverKind(i32()))
  doAssert at == blob.len, "trailing bytes in map " & name
  let cx = result.nx-1
  result.cellMaxHeight = newSeq[int16](cx*(result.nz-1))
  result.cellMinMargin = newSeq[int16](cx*(result.nz-1))
  for j in 0..<result.nz-1:
    for i in 0..<cx:
      let k = j*result.nx+i
      result.cellMaxHeight[j*cx+i] = max(max(result.heights[k], result.heights[k+1]),
        max(result.heights[k+result.nx], result.heights[k+result.nx+1]))
      result.cellMinMargin[j*cx+i] = min(min(result.margins[k], result.margins[k+1]),
        min(result.margins[k+result.nx], result.margins[k+result.nx+1]))

# Parsed once at startup, before any thread runs, and never written again.
var paintbotMaps: seq[PaintbotMap] = block:
  var maps: seq[PaintbotMap]
  for i, name in MapNames: maps.add parseMap(name, MapBlobs[i])
  maps

# One more than the active map's index, so a fresh thread's zero means the rules' own island.
when defined(pwTraining):
  var mapSlot {.threadvar.}: int
else:
  var mapSlot = 0
proc activeMap*(): int {.inline.} = mapSlot-1
  ## Index into MapNames, or -1 for the rules' own island.
proc setActiveMap*(index: int) =
  doAssert index in -1..<MapNames.len
  mapSlot = index+1

proc mapIndex*(name: string): int =
  ## -1 for "" (the rules' island); raises for a name that is not a map.
  if name.len == 0: return -1
  for i, n in MapNames:
    if n == name: return i
  raise newException(ValueError, "Unknown Paintbot map: " & name)

proc currentMap*(): ptr PaintbotMap =
  ## The active map; only valid while activeMap() >= 0.
  {.cast(gcsafe).}: result = paintbotMaps[activeMap()].addr

proc sampleGrid(m: PaintbotMap, margins: bool, x, z: int, outside: int): int =
  ## Integer bilinear interpolation; exact under the half turn, since the grid is its own
  ## mirror and every grid point maps onto a grid point.
  let fx = x-m.x0; let fz = z-m.z0
  if fx < 0 or fz < 0 or fx > (m.nx-1)*m.step or fz > (m.nz-1)*m.step: return outside
  let i = min(fx div m.step, m.nx-2); let j = min(fz div m.step, m.nz-2)
  let tx = int64(fx-i*m.step); let tz = int64(fz-j*m.step); let s = int64(m.step)
  let k = j*m.nx+i
  # Index the grid in place: an expression choosing between the two seqs would copy one.
  template at(n: int): int64 = (if margins: m.margins[n].int64 else: m.heights[n].int64)
  let h00 = at(k); let h10 = at(k+1)
  let h01 = at(k+m.nx); let h11 = at(k+m.nx+1)
  int((h00*(s-tx)*(s-tz)+h10*tx*(s-tz)+h01*(s-tx)*tz+h11*tx*tz) div (s*s))

proc mapCell*(x, z: int): int =
  ## The active map's grid cell that sampleGrid interpolates (x, z) in (cellMaxHeight /
  ## cellMinMargin index), or -1 when the point lies outside the grid.
  {.cast(gcsafe).}:
    let m = paintbotMaps[activeMap()].addr
    let fx = x-m.x0; let fz = z-m.z0
    if fx < 0 or fz < 0 or fx > (m.nx-1)*m.step or fz > (m.nz-1)*m.step: return -1
    min(fz div m.step, m.nz-2)*(m.nx-1)+min(fx div m.step, m.nx-2)
proc mapCellMaxHeight*(cell: int): int =
  {.cast(gcsafe).}: paintbotMaps[activeMap()].cellMaxHeight[cell].int
proc mapCellMinMargin*(cell: int): int =
  {.cast(gcsafe).}: paintbotMaps[activeMap()].cellMinMargin[cell].int
proc mapHeight*(x, z: int): int =
  {.cast(gcsafe).}: paintbotMaps[activeMap()].sampleGrid(false, x, z, -600)
proc mapMargin*(x, z: int): int =
  {.cast(gcsafe).}: paintbotMaps[activeMap()].sampleGrid(true, x, z, -1000)

when defined(pwTraining):
  # Training-only map registration (native pw_register_map). A training process may append
  # up to MaxTrainingMaps maps (training arenas, mapgen --layout-scale) after MapNames, from
  # PBMAP001 blobs, before it creates any world: paintbotMaps is read by every thread without
  # a lock, so it may only grow while nothing reads it. Registered maps take indices
  # MapNames.len ..< mapCount() everywhere an activeMap() index is used (terrain tables, the
  # parked cover and nav caches size for them); the hosted MapNames, mapIndex and config
  # "map" names are unchanged, so a registered map is reachable only by index (pw_set_map).
  const MaxTrainingMaps* = 8
  proc mapCount*(): int =
    ## Compiled maps plus registered ones: the indices setActiveMapAny accepts (besides -1).
    {.cast(gcsafe).}: paintbotMaps.len
  proc mapNameAt*(index: int): string =
    {.cast(gcsafe).}: paintbotMaps[index].name
  proc validMapBlob(blob: string): bool =
    ## The structural checks parseMap asserts, as a predicate: the header, an exact length for
    ## its counts, and every enum field in range.
    if blob.len < 52 or blob[0..7] != "PBMAP001": return false
    proc at32(k: int): int =
      int(cast[int32](uint32(blob[k].uint8) or (uint32(blob[k+1].uint8) shl 8) or
        (uint32(blob[k+2].uint8) shl 16) or (uint32(blob[k+3].uint8) shl 24)))
    let nx = at32(8); let nz = at32(12); let step = at32(24)
    let counts = [at32(36), at32(40), at32(44), at32(48)]
    if nx < 2 or nz < 2 or nx > 4096 or nz > 4096 or step <= 0: return false
    for c in counts:
      if c < 0 or c > 100_000: return false
    let pickupsAt = 52+nx*nz*4+counts[0]*12
    let coverAt = pickupsAt+counts[1]*12+counts[2]*16
    if blob.len != coverAt+counts[3]*16: return false
    for k in 0..<counts[1]:
      if at32(pickupsAt+k*12+8) notin 0..7: return false
    for k in 0..<counts[3]:
      if at32(coverAt+k*16+12) notin ord(MapCoverKind.low)..ord(MapCoverKind.high): return false
    true
  proc registerTrainingMap*(name, blob: string): int =
    ## Appends a PBMAP001 map after the compiled ones and returns its index; -1 for an empty or
    ## taken name, a malformed blob, or a full registry. The caller guarantees that no thread
    ## reads the maps meanwhile (native_env: before any handle exists).
    {.cast(gcsafe).}:
      if name.len == 0 or name.len > 31 or paintbotMaps.len >= MapNames.len+MaxTrainingMaps or
          not validMapBlob(blob): return -1
      for m in paintbotMaps:
        if m.name == name: return -1
      paintbotMaps.add parseMap(name, blob)
      paintbotMaps.high
  proc setActiveMapAny*(index: int) =
    ## setActiveMap over compiled and registered maps.
    doAssert index in -1..<mapCount()
    mapSlot = index+1
