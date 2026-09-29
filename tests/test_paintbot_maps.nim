## Rules 41 maps: each generated map loads, is its own half-turn image, connects every
## objective to both homes, and survives a recorded replay round trip.
import std/[unittest, sets, deques, os, strutils]
import polyworld/tapes
import ../examples/paintbot/[sim, game]

proc mirrored(p: Point): Point = point(Width-p.x.int, Height-p.z.int)

suite "Paintbot generated maps":
  setup:
    visionRulesVersion = 45
    replayRulesVersion = 45
  teardown:
    configureMap("")

  test "the island stays the default and unknown names are refused":
    configureMap("")
    check mapName() == ""
    check home(0) == point(Width*15 div 100, Height div 2)
    expect ValueError: configureMap("nowhere")

  for name in MapNames:
    test name & " loads with the rules-40 item set, mirrored":
      configureMap(name)
      let w = newWorld(2026)
      check mapName() == name
      # Ten hearts, or one per ~730 m2 of land on big-* maps (mapgen --heart-area 730).
      if name.startsWith("big-"): check w.controlHearts.len >= 90
      else: check w.controlHearts.len == 10
      check w.controlHearts.len mod 2 == 0
      check w.controlHearts[0].owner == 0 and w.controlHearts[1].owner == 1
      check w.controlHearts[0].pos == home(0) and w.controlHearts[1].pos == home(1)
      check home(1) == mirrored(home(0))
      var kinds: array[PickupKind, int]
      for p in w.pickups: inc kinds[p.kind]
      # Items and trenches scale with the hearts: one rules-40 set per ten hearts.
      let copies = max(1, (w.controlHearts.len+5) div 10)
      check kinds == [4*copies, 2*copies, 4*copies, 2*copies, 2*copies] # grenade, spray, medkit, armor, uniform
      check w.trenches.len == 6*copies
      check w.cover.len == currentMap().cover.len
      for i in countup(0, w.controlHearts.len-2, 2):
        check w.controlHearts[i+1].pos == mirrored(w.controlHearts[i].pos)
      for i in countup(0, w.pickups.len-2, 2):
        check w.pickups[i+1].pos == mirrored(w.pickups[i].pos)
        check w.pickups[i+1].kind == w.pickups[i].kind
      for x in countup(minX(), maxX(), 170):
        for z in countup(minZ(), maxZ(), 130):
          check terrainHeight(x, z) == terrainHeight(Width-x, Height-z)
          check islandMargin(x, z) == islandMargin(Width-x, Height-z)
      for i in 0..<Seats:
        check not w.blocked(w.cogs[i].pos)

    test name & " connects every heart and item to both homes":
      configureMap(name)
      let w = newWorld(2026)
      var visited: HashSet[(int, int)]
      var queue: Deque[(int, int)]
      let start = (home(0).x.int div 50, home(0).z.int div 50)
      queue.addLast(start); visited.incl(start)
      while queue.len > 0:
        let p = queue.popFirst()
        for d in [(1, 0), (-1, 0), (0, 1), (0, -1)]:
          let n = (p[0]+d[0], p[1]+d[1])
          if n in visited or w.blocked(point(n[0]*50, n[1]*50)): continue
          if not w.traversable(point(p[0]*50, p[1]*50), point(n[0]*50, n[1]*50)): continue
          visited.incl(n); queue.addLast(n)
      proc reached(p: Point): bool =
        # The nearest lattice point may sit inside a neighbour's clearance; any corner will do.
        for dx in 0..1:
          for dz in 0..1:
            if (p.x.int div 50+dx, p.z.int div 50+dz) in visited: return true
      check reached(home(1))
      for h in w.controlHearts: check reached(h.pos)
      for p in w.pickups: check reached(p.pos)

    test name & " replays from its recording":
      configureMap(name)
      recording = Recording(seed: 2026, endTick: HeartMeterMatchTicks, map: mapName())
      world = newWorld(recording.seed, recording.endTick)
      var commands: array[LegacySeats, Command]
      for i in 0..<Seats:
        commands[i] = Command(walk: true, goal: world.controlHearts[2+i mod 8].pos, shoot: i mod 3 == 0)
      for tick in 0..<360:
        world.step(commands)
        recording.frames.add Frame(commands: @(commands), hash: world.stateHash())
      let path = getTempDir()/("paintbot-map-" & name & ".replay")
      defer: removeFile(path)
      saveRecordingAs(path, 45, recording)
      configureMap("")
      let loaded = loadRecording(path)
      check loaded.map == name
      configureMap(loaded.map)
      var again = newWorld(loaded.seed, loaded.endTick)
      for f in loaded.frames:
        again.step(f.commands)
        check again.stateHash() == f.hash
