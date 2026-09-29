## Rules 42 team vision: every visibility answer equals a sight line from some living
## teammate on the shared grid, teammates always see each other, the default stays per-cog,
## and a recording keeps its vision mode through a replay.
import std/[unittest, random, os]
import polyworld/[visions, tapes]
import ../examples/paintbot/[sim, game]

proc cellOf(g: tuple[nx, nz, originX, originZ: int, terrain, blockers: seq[int16]], p: Point): (int32, int32) =
  (int32(clamp((p.x.int-g.originX) div SightCell, 0, g.nx-1)), int32(clamp((p.z.int-g.originZ) div SightCell, 0, g.nz-1)))

proc referenceSees(w: World, side: int, p: Point): bool =
  let g = w.teamSightGrid()
  if p.x < g.originX or p.z < g.originZ: return false
  if (p.x.int-g.originX) div SightCell >= g.nx or (p.z.int-g.originZ) div SightCell >= g.nz: return false
  let t = cellOf(g, p)
  for i in 0..<Seats:
    if team(i) != side or w.cogs[i].hp <= 0: continue
    let s = cellOf(g, w.cogs[i].pos)
    if lineVisible(g.nx.int32, g.nz.int32, g.terrain, g.blockers, s[0], s[1], t[0], t[1],
        (VisionRange div SightCell).int32, 3, 3): return true

suite "Team vision (rules 42)":
  setup:
    visionRulesVersion = 42
    replayRulesVersion = 42
  teardown:
    configureVision("")
    configureMap("")

  test "the default keeps per-cog sight lines":
    configureVision("")
    check visionMode() == "" and not teamVision
    expect ValueError: configureVision("fog")

  for name in ["", "crater", "deep-forest", "badlands"]:
    test "every answer matches a teammate's sight line on " & (if name == "": "Heartwick" else: name):
      configureMap(name)
      configureVision("team")
      var w = newWorld(2026)
      var rng = initRand(3)
      var commands: array[LegacySeats, Command]
      let g = w.teamSightGrid()
      var blocked = 0
      for b in g.blockers:
        if b > 0: inc blocked
      check blocked > 0
      for tick in 0..<600:
        if tick mod 50 == 0:
          for i in 0..<Seats:
            commands[i] = Command(walk: true, goal: point(rng.rand(minX()+300..maxX()-300), rng.rand(minZ()+300..maxZ()-300)))
        w.step(commands)
        if tick mod 100 == 99:
          for slot in 0..<Seats:
            for other in 0..<Seats:
              let expected =
                if w.cogs[other].hp <= 0: false
                elif slot == other: true
                elif w.cogs[slot].hp <= 0: false
                elif team(slot) == team(other): true
                else: referenceSees(w, team(slot), w.cogs[other].pos)
              check w.visible(slot, other) == expected
            for pk in w.pickups:
              check w.canSeePoint(slot, pk.pos) == (w.cogs[slot].hp > 0 and referenceSees(w, team(slot), pk.pos))

  test "a recording keeps its vision mode through a replay":
    configureMap("")
    configureVision("team")
    recording = Recording(seed: 2026, endTick: HeartMeterMatchTicks, map: mapName(), vision: visionMode())
    world = newWorld(recording.seed, recording.endTick)
    var commands: array[LegacySeats, Command]
    for i in 0..<Seats: commands[i] = Command(walk: true, goal: home(1-team(i)), shoot: true)
    for tick in 0..<240:
      world.step(commands)
      recording.frames.add Frame(commands: @(commands), hash: world.stateHash())
    let path = getTempDir()/"paintbot-team-vision.replay"
    defer: removeFile(path)
    saveRecording(path, recording)
    configureVision("")
    let loaded = loadRecording(path)
    check loaded.vision == "team"
    check teamVision
    var again = newWorld(loaded.seed, loaded.endTick)
    for f in loaded.frames:
      again.step(f.commands)
      check again.stateHash() == f.hash
