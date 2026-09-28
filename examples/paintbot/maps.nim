## Procedural maps from coworld/paintbot/tools/mapgen, compiled into the engine and viewer.
## A map replaces the rules-derived island: its terrain grid answers terrainHeight and
## islandMargin, and its hearts, pickups, trenches and cover replace the fixed layout. Every
## map is its own image under the rules-35 half turn about (3200, 2000).
import std/strutils
const ShippedMaps = ["twin-mesas", "archipelago", "serpent-river", "crater", "terraces",
  "deep-forest", "badlands", "atoll", "highlands", "delta"]
when defined(pwBenchMaps):
  # Benchmark-only maps at ten times the area (tests/bench_paintbot_maps.nim); never shipped.
  const MapNames* = block:
    var names: array[ShippedMaps.len+2, string]
    for i, n in ShippedMaps: names[i] = n
    names[^2] = "big-twin-mesas"; names[^1] = "big-deep-forest"
    names
else:
  const MapNames* = ShippedMaps

const MapBlobs = block:
  var blobs: array[MapNames.len, string]
  for i, name in MapNames:
    blobs[i] = staticRead("maps/" & (if name.startsWith("big-"): "bench/" else: "") & name & ".pbmap")
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

proc mapHeight*(x, z: int): int =
  {.cast(gcsafe).}: paintbotMaps[activeMap()].sampleGrid(false, x, z, -600)
proc mapMargin*(x, z: int): int =
  {.cast(gcsafe).}: paintbotMaps[activeMap()].sampleGrid(true, x, z, -1000)
