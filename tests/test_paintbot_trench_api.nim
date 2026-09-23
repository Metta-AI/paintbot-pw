## BASIC can see trench geometry: count, centre, extent, and whether a point is inside one.
## Trenches are public map geometry (the tactical map outlines them), so none of this is
## fog-gated; testing an enemy's position still needs that enemy to be visible.
import std/[unittest, os, strutils]
import polyworld/[cli, basic]
import ../examples/paintbot/[sim, bots, oracle, game, topography]

proc run(source: string, w: var World): seq[string] =
  let path = getTempDir()/"paintbot-trench-api.bas"
  writeFile(path, source)
  defer: removeFile(path)
  let players = loadBots(@[BotGroup(path: path, count: Seats)])
  discard players.decide(w)
  shouts[0]

suite "BASIC trench geometry":
  test "count, centre and extent match the world's trenches":
    var w = newWorld(4)
    check w.trenches.len > 0
    let t = w.trenches[0]
    # A cog may shout at most four times a decision, so ask in two batches.
    let a = run("""
shout(strFromInt(trenchCount()))
shout(strFromInt(trenchX(0)))
shout(strFromInt(trenchY(0)))
shout(strFromInt(trenchW(0)))
""", w)
    check a[0] == $w.trenches.len
    check a[1] == $(t.x + t.w div 2)
    check a[2] == $(t.z + t.h div 2)
    check a[3] == $t.w
    var w2 = newWorld(4)
    let b = run("""
shout(strFromInt(trenchH(0)))
shout(strFromInt(trenchX(-1)))
shout(strFromInt(trenchX(9999)))
""", w2)
    check b[0] == $t.h
    check b[1] == "-1"
    check b[2] == "-1"

  test "trenchAt agrees with the engine's own containment test":
    var w = newWorld(4)
    let t = w.trenches[0]
    let inside = Point(x: t.x + t.w div 2, z: t.z + t.h div 2)
    let outside = Point(x: t.x - 500, z: t.z - 500)
    let got = run("shout(strFromInt(trenchAt(" & $inside.x & ", " & $inside.z & ")))\n" &
                  "shout(strFromInt(trenchAt(" & $outside.x & ", " & $outside.z & ")))\n", w)
    check got[0] == $w.trenchAt(inside)
    check got[0] != "-1"
    check got[1] == $w.trenchAt(outside)

  test "waterAt agrees with the movement rule that slows a cog to a quarter":
    var w = newWorld(4)
    # Find one wet and one dry point on the map with the engine's own test.
    var wet, dry = Point(x: -1, z: -1)
    var z = minZ() + 200
    while z < maxZ() - 200 and (wet.x < 0 or dry.x < 0):
      var x = minX() + 200
      while x < maxX() - 200:
        let isWet = riverBlend(x, z) > 0 and terrainHeight(x, z) < RiverWaterHeight
        if isWet and wet.x < 0: wet = Point(x: x.int32, z: z.int32)
        if not isWet and dry.x < 0: dry = Point(x: x.int32, z: z.int32)
        x += 150
      z += 150
    check wet.x >= 0
    check dry.x >= 0
    let got = run("shout(strFromInt(waterAt(" & $wet.x & ", " & $wet.z & ")))\n" &
                  "shout(strFromInt(waterAt(" & $dry.x & ", " & $dry.z & ")))\n", w)
    check got[0] == "1"
    check got[1] == "0"
