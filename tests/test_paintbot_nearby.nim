## nearAgents: the grid query returns exactly what a full scan of the roster would, under the
## identities the observer sees; and nearby.bas plays a match on it without a seat failing.
import std/[unittest, random, algorithm]
import ../examples/paintbot/[sim, bots]
import polyworld/cli

proc bruteNear(w: World, slot, radius: int): seq[tuple[identity, body: int]] =
  if w.cogs[slot].hp <= 0: return
  let r = clamp(radius, 0, 20000)
  var best: seq[tuple[identity, body: int, d2: int64]]
  for b in 0..<Seats:
    if b == slot or w.cogs[b].hp <= 0: continue
    let d2 = distance2(w.cogs[slot].pos, w.cogs[b].pos)
    if d2 > r.int64*r or not w.visible(slot, b): continue
    let identity = w.observedSeat(slot, b)
    var dup = -1
    for i, e in best:
      if e.identity == identity: dup = i
    if dup < 0: best.add (identity, b, d2)
    elif d2 < best[dup].d2 or (d2 == best[dup].d2 and b < best[dup].body): best[dup] = (identity, b, d2)
  best.sort(proc(a, b: tuple[identity, body: int, d2: int64]): int =
    if a.d2 != b.d2: cmp(a.d2, b.d2) else: cmp(a.identity, b.identity))
  for e in best[0..<min(best.len, 64)]: result.add (e.identity, e.body)

suite "nearAgents":
  test "matches a full scan at every radius, with and without disguises":
    var rng = initRand(7)
    for seed in [2026'i32, 11, 99]:
      var w = newWorld(seed)
      var commands: array[Seats, Command]
      for tick in 0..<480:
        if tick mod 40 == 0:
          for i in 0..<Seats:
            commands[i] = Command(walk: true, goal: point(rng.rand(minX()+200..maxX()-200), rng.rand(minZ()+200..maxZ()-200)),
              aim: point(rng.rand(minX()..maxX()), rng.rand(minZ()..maxZ())))
        w.step(commands)
        if tick mod 60 == 59:
          if visionRulesVersion >= 27:
            for i in 0..<Seats: w.uniforms[i] = rng.rand(3) == 0
          for slot in 0..<Seats:
            for radius in [0, 900, 3000, 5250, 20000, 90000]:
              check nearAgentsFor(w, slot, radius) == bruteNear(w, slot, radius)

  test "nearby.bas plays a minute without a seat failing":
    var bots = loadBots(@[BotGroup(path: "examples/paintbot/players/nearby.bas", count: Seats)])
    var w = newWorld(2026)
    for tick in 0..<1440:
      let commands = bots.decide(w)
      w.step(commands)
      if w.winner != -1: break
    for i in 0..<Seats:
      check not bots[i].failed
      if bots[i].failed: echo "seat ", i, ": ", bots[i].error
