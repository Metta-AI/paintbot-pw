## pw_damage_events (training library only): the per-hit damage log with a weapon code finer than DamageWeapon
## (0 other / map, 1 gun, 2 grenade, 3 spray, 4 sniper, 5 self-destruct), drained like pw_kill_events. Over scripted
## rules-49 matches (base.bas; a base.bas "bomber" that self-destructs next to a visible foe; the island and maps with
## sniper pickups), every step:
## - the events equal pw_hit_events' (hit log on) one for one: attacker, victim, health, armor, killed, final, and the
##   weapon after folding (4 -> 1, 5 -> 2);
## - a gun hit is 4 exactly when the shooter carried the sniper at the step's start and end (a shooter that took or
##   lost the rifle during the step is not judged);
## - every 5 comes from a seat that ordered a self-destruct (pw_seat_orders_ex) on that step, and that seat's own
##   death is a 5 too;
## and at the end, by victim, the events sum to pw_seat_damage_taken_stats (hits, health) and the killed ones equal
## pw_kill_events (tick, attacker, victim, folded weapon, final). Draining every tick changes nothing (state hashes
## equal a match that never drains). Bad arguments, peek (capacity 0) and partial drains are checked too.
## Build with --mm:arc --threads:on -d:pwTraining -d:headless.
import std/[unittest, os, importutils]
import ../examples/paintbot/[sim, neural_contract, native_env]

when not defined(pwTraining): {.error: "pw_damage_events exists only under -d:pwTraining".}

privateAccess(NativeEnv)
const Root = currentSourcePath().parentDir.parentDir
type Buffer = ptr UncheckedArray[cfloat]
template fbuf(a: untyped): Buffer = cast[Buffer](addr a[0])
template ibuf(a: untyped): ptr UncheckedArray[int32] = cast[ptr UncheckedArray[int32]](addr a[0])
type Ev = array[8, int32]

const BomberTail = """

i = 0
while i < 16
  if i mod 2 <> selfTeam and visible(i) then
    dx = playerX(i) - selfX
    dy = playerY(i) - selfY
    if dx * dx + dy * dy <= 72900 then
      selfDestruct()
    end if
  end if
  i = i + 1
wend
"""

proc mapIndex(name: string): cint =
  if name == "": return -1
  for i, m in MapNames:
    if m == name: return i.cint
  doAssert false, "unknown map " & name

proc scripted(seed, ticks: int32, map, red, blue: string): pointer =
  result = pw_create(seed, ticks)
  doAssert result != nil
  doAssert pw_set_rules(result, 49) == 0
  doAssert pw_set_map(result, mapIndex(map)) == 0
  doAssert pw_reset(result, seed, ticks) == 0
  for slot in 0..<Seats:
    let src = if slot mod 2 == 0: red else: blue
    doAssert pw_set_seat_script(result, slot.cint, cast[ptr UncheckedArray[char]](unsafeAddr src[0]), src.len.int32) == 0

proc drainAll(h: pointer, capacity = 3): seq[Ev] =
  var buf = newSeq[int32](capacity*8)
  while true:
    let n = pw_damage_events(h, ibuf(buf), capacity.cint)
    doAssert n >= 0 and n <= capacity
    for i in 0..<n:
      var e: Ev
      for k in 0..<8: e[k] = buf[i*8+k]
      result.add e
    if n < capacity: break

proc fold(code: int32): int32 = (if code == 4: 1'i32 elif code == 5: 2'i32 else: code)

suite "pw_damage_events":
  test "bad arguments, peek and partial drain":
    let h = scripted(4931, 600, "", readFile(Root / "coworld/paintbot/players/base.bas"),
      readFile(Root / "coworld/paintbot/players/base.bas"))
    var buf: array[16, int32]
    check pw_damage_events(nil, ibuf(buf), 1) == -1
    check pw_damage_events(h, nil, 1) == -1
    check pw_damage_events(h, ibuf(buf), -1) == -1
    check pw_damage_events(h, nil, 0) == 0
    var actions: array[LegacySeats*ActionSizes.len, int32]
    var rewards, terminals: array[LegacySeats, float32]
    var pending = 0
    for t in 0..<600:
      doAssert pw_step(h, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
      pending = pw_damage_events(h, nil, 0)
      if pending >= 3 or terminals[0] == 1: break
    check pending >= 2
    check pw_damage_events(h, ibuf(buf), 1) == 1                  # partial: one written, the rest stay
    check pw_damage_events(h, nil, 0) == pending - 1
    doAssert pw_reset(h, 4931, 600) == 0
    check pw_damage_events(h, nil, 0) == 0                        # reset clears
    pw_destroy(h)

  test "== pw_hit_events (folded), sniper / self-destruct codes, sums, kill log; draining changes nothing":
    let base = readFile(Root / "coworld/paintbot/players/base.bas")
    let bomber = base & BomberTail
    var total, sniperHits, sdEvents, sdOwn, judged: int
    for (seed, map, red, blue) in [(4941'i32, "", base, bomber), (4942'i32, "twin-mesas", bomber, base),
        (4943'i32, "crater", base, bomber), (4944'i32, "twin-mesas", base, base), (4945'i32, "atoll", bomber, base)]:
      let a = scripted(seed, 14400, map, red, blue)
      let b = scripted(seed, 14400, map, red, blue)   # never drained, no hit log
      doAssert pw_set_hit_log(a, 1) == 0
      let env = cast[ptr NativeEnv](a)
      var actions: array[LegacySeats*ActionSizes.len, int32]
      var rewards, terminals, t2: array[LegacySeats, float32]
      var all: seq[Ev]
      var kills: seq[array[5, int32]]
      for t in 0..<14400:
        var pre: array[16, bool]
        for s in 0..<Seats: pre[s] = env.world.hasSniper(s)
        doAssert pw_step(a, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
        doAssert pw_step(b, ibuf(actions), fbuf(rewards), fbuf(t2)) == 0
        check pw_state_hash(a) == pw_state_hash(b)
        let evs = drainAll(a)
        let nh = pw_hit_events(a, nil, 0)
        var hits = newSeq[int32](max(1, nh)*8)
        doAssert pw_hit_events(a, ibuf(hits), nh) == nh
        check evs.len == nh
        var ordered: array[16, int32]
        for s in 0..<Seats:
          var o: array[11, int32]
          doAssert pw_seat_orders_ex(a, s.cint, ibuf(o)) == 0
          ordered[s] = o[10]
        for i in 0..<min(evs.len, nh):
          let e = evs[i]
          check e[1] == hits[i*8] and e[2] == hits[i*8+1] and e[4] == hits[i*8+2] and e[5] == hits[i*8+3]
          check fold(e[3]) == hits[i*8+4] and e[6] == hits[i*8+5] and e[7] == hits[i*8+6]
          if e[3] in [1'i32, 4]:
            let post = e[1] >= 0 and env.world.hasSniper(e[1])
            if e[1] >= 0 and pre[e[1]] == post:
              inc judged
              check (e[3] == 4) == pre[e[1]]
            if e[3] == 4: inc sniperHits
          if e[3] == 5:
            inc sdEvents
            check e[1] >= 0 and ordered[e[1]] == 1
            if e[1] == e[2]:
              inc sdOwn
              check e[6] == 1
        var kb: array[64*5, int32]
        while true:
          let n = pw_kill_events(a, ibuf(kb), 64)
          for i in 0..<n: kills.add [kb[i*5], kb[i*5+1], kb[i*5+2], kb[i*5+3], kb[i*5+4]]
          if n < 64: break
        all.add evs
        if terminals[0] == 1: break
      total += all.len
      for v in 0..<Seats:
        var st: array[8, int32]
        doAssert pw_seat_damage_taken_stats(a, v.cint, ibuf(st)) == 0
        var hitsN, health: int32
        for e in all:
          if e[2] == v: inc hitsN; health += e[4]
        check hitsN == st[0] + st[2] + st[4] + st[6]
        check health == st[1] + st[3] + st[5] + st[7]
      var deaths: seq[array[5, int32]]
      for e in all:
        if e[6] == 1: deaths.add [e[0], e[1], e[2], fold(e[3]), e[7]]
      check deaths == kills
      pw_destroy(a); pw_destroy(b)
    check total > 0 and sdEvents > 0 and sdOwn > 0 and judged > 0
    echo "damage log: ", total, " events; ", sniperHits, " sniper hits; ", sdEvents, " self-destruct events (",
      sdOwn, " bombers); ", judged, " gun hits judged against the shooter's sniper"
