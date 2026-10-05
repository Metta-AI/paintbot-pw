## Rules-49 item state in the training library: pw_seat_items (per seat: sniper, windex-mister, radar, the shared
## gun / sniper cooldown, reach, spray can, self-destruct readiness), pw_seat_pickups (pickups taken per seat by kind
## 0..7) and pw_pickups (every pickup: position, kind, ready, ticks until ready).
## - Calling all three after every step changes nothing: state hashes and executed orders equal a run that never calls
##   them (rules 40 / 48 / 49, Heartwick and a generated map).
## - Every pw_seat_items field equals a reference read straight off the world's raw fields AND the seat's BASIC
##   builtins (hasSniper, mistingTicks, radarTicks, radarBoost, gunRange, hasSpray, playerMisting / playerRadar of
##   itself) on every alive row of base.bas matches; dead rows are zeros.
## - pw_seat_pickups: kinds 0..4 equal pw_seat_equip_stats every tick, kinds 5..7 the world's own transitions (a sniper
##   gained, a mister or radar started), and each kind's total the pickups re-armed (readyAt) that tick.
## - pw_pickups equals the world's pickups and pw_world_json's; row i is the pickup BASIC pickupX/Y/Kind(i) and the
##   movement head's choice 11 + i reach, and every pickup index is below 32 on the island and the generated maps.
## - Stepped mechanics: the sniper's 96-tick shot (288 under armour), the mister's and radar's last tick (flag 1, ticks
##   0), the heal phase, the boost around a carrier, death zeroing the row, rules 48 reading no items.
## - pw_world_save / load carries the pickup counts; reset clears them.
## Build with --mm:arc --threads:on -d:pwTraining. PW_ITEMS_SEEDS=N PW_ITEMS_TICKS=T widen the matches.
import std/[unittest, os, strutils, importutils, json]
import ../examples/paintbot/[sim, neural_contract, native_env, seat_view]

when not defined(pwTraining): {.error: "the native ABI exists only under -d:pwTraining".}

privateAccess(NativeEnv)
const
  Root = currentSourcePath().parentDir.parentDir
  Base = Root / "coworld/paintbot/players/base.bas"
  Jev = Root / "coworld/paintbot/players/jev.bas"
  F = SeatItemFloats
type
  Buffer = ptr UncheckedArray[cfloat]
  Actions = array[LegacySeats*ActionSizes.len, int32]
  ItemRow = array[SeatItemFloats, float32]
template fbuf(a: untyped): Buffer = cast[Buffer](addr a[0])
template ibuf(a: untyped): ptr UncheckedArray[int32] = cast[ptr UncheckedArray[int32]](addr a[0])
template cbuf(s: string): ptr UncheckedArray[char] =
  (if s.len > 0: cast[ptr UncheckedArray[char]](unsafeAddr s[0]) else: nil)

proc envOf(h: pointer): ptr NativeEnv = cast[ptr NativeEnv](h)

proc mapIndex(name: string): cint =
  if name == "": return -1
  for i, m in MapNames:
    if m == name: return i.cint
  doAssert false, "unknown map " & name

proc newHandle(seed, ticks, rules: int32, map = ""): pointer =
  result = pw_create(seed, ticks)
  doAssert result != nil
  doAssert pw_set_rules(result, rules) == 0
  doAssert pw_set_map(result, mapIndex(map)) == 0
  doAssert pw_reset(result, seed, ticks) == 0

proc script(h: pointer, seat: int, source: string) =
  doAssert pw_set_seat_script(h, seat.cint, cbuf(source), source.len.int32) == 0

proc scripted(seed, ticks, rules: int32, red, blue: string, map = ""): pointer =
  result = newHandle(seed, ticks, rules, map)
  for slot in 0..<Seats: result.script(slot, if slot mod 2 == 0: red else: blue)

proc step(h: pointer, actions: var Actions): bool =
  ## One pw_step; true when the match ended.
  var rewards, terminals: array[LegacySeats, float32]
  doAssert pw_step(h, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
  terminals[0] == 1

proc idle(h: pointer, ticks = 1) =
  var actions: Actions
  for t in 0..<ticks: discard h.step(actions)

proc items(h: pointer): seq[ItemRow] =
  var flat = newSeq[float32](Seats*F)
  doAssert pw_seat_items(h, fbuf(flat)) == 0
  result = newSeq[ItemRow](Seats)
  for s in 0..<Seats:
    for k in 0..<F: result[s][k] = flat[s*F+k]

proc pickupCounts(h: pointer): seq[int32] =
  result = newSeq[int32](Seats*PickupKinds)
  doAssert pw_seat_pickups(h, ibuf(result)) == 0

proc pickupRows(h: pointer): seq[float32] =
  let n = pw_pickups(h, nil, 0)
  doAssert n >= 0
  result = newSeq[float32](max(1, n)*PickupFloats)
  doAssert pw_pickups(h, fbuf(result), n) == n
  result.setLen(n*PickupFloats)

proc reference(w: World, s: int): ItemRow =
  ## pw_seat_items' row from the world's raw fields (not mechanics' accessors).
  if w.cogs[s].hp <= 0: return
  let sniper = w.sniper[s]
  let misting = w.misterUntil[s] > 0
  let radar = w.radarUntil[s] > 0
  var boosted = false
  for r in 0..<Seats:
    let dx = int64(w.cogs[r].pos.x - w.cogs[s].pos.x)
    let dz = int64(w.cogs[r].pos.z - w.cogs[s].pos.z)
    if w.radarUntil[r] > 0 and w.cogs[r].hp > 0 and dx*dx + dz*dz <= 800'i64*800: boosted = true
  let left = if misting: w.misterUntil[s] - w.tick else: 0
  result[0] = float32(sniper.int)
  result[1] = float32(misting.int)
  result[2] = left.float32
  result[3] = (if misting: float32(left mod 360) else: 0)
  result[4] = float32(radar.int)
  result[5] = (if radar: float32(w.radarUntil[s] - w.tick) else: 0)
  result[6] = float32(boosted.int)
  result[7] = float32((misting or radar).int)
  result[8] = w.cogs[s].cooldown.float32
  result[9] = float32(if sniper: 4800 elif visionRulesVersion >= 49: 2133 else: 5250)
  result[10] = float32(w.equipment[s].sprayCan.int)
  result[11] = float32((visionRulesVersion >= 49 and not (misting or radar)).int)

proc builtins(w: World, s: int): ItemRow =
  ## The same row from the seat's BASIC perception (an alive seat only); fields BASIC has no builtin for
  ## (heal phase, disarmed, cooldown, self-destruct) are copied from the reference.
  beginViews(w)
  let v = seatView(s)
  result = reference(w, s)
  result[0] = v.hasSniper.float32
  result[1] = v.playerMisting(s).float32
  result[2] = v.mistingTicks.float32
  result[4] = v.playerRadar(s).float32
  result[5] = v.radarTicks.float32
  result[6] = v.radarBoost.float32
  result[9] = v.gunRange.float32
  result[10] = v.hasSpray.float32

suite "Training library: rules-49 item state":
  let baseSource = readFile(Base)
  let jevSource = readFile(Jev)
  let seeds = parseInt(getEnv("PW_ITEMS_SEEDS", "2"))
  let matchTicks = parseInt(getEnv("PW_ITEMS_TICKS", "3000"))

  test "arguments":
    let h = newHandle(1, 100, 49)
    var f: array[SeatItemFloats*LegacySeats, float32]
    var i: array[PickupKinds*LegacySeats, int32]
    check pw_seat_items(nil, fbuf(f)) == -1
    check pw_seat_items(h, nil) == -1
    check pw_seat_pickups(nil, ibuf(i)) == -1
    check pw_seat_pickups(h, nil) == -1
    check pw_pickups(nil, nil, 0) == -1
    check pw_pickups(h, nil, -1) == -1
    check pw_pickups(h, nil, 1) == -1
    let n = pw_pickups(h, nil, 0)
    check n == envOf(h).world.pickups.len and n > 0
    var one: array[PickupFloats, float32]
    check pw_pickups(h, fbuf(one), 1) == n      # one row written, the count returned
    check one[0] == envOf(h).world.pickups[0].pos.x.float32
    check pw_seat_items(h, fbuf(f)) == 0 and pw_seat_pickups(h, ibuf(i)) == 0
    for v in i: check v == 0
    pw_destroy(h)

  test "calling every export after every step leaves scripted worlds byte-identical":
    for (rules, map) in [(40'i32, ""), (48'i32, ""), (49'i32, ""), (49'i32, "twin-mesas")]:
      checkpoint "rules " & $rules & " map " & map
      var hashes: array[2, seq[uint32]]
      var orders: array[2, seq[int32]]
      for calls in 0..1:
        let h = scripted(31, 2000, rules, baseSource, jevSource, map)
        var actions: Actions
        var o: array[10, int32]
        for t in 0..<2000:
          let ended = h.step(actions)
          if calls == 1:
            discard h.items
            discard h.pickupCounts
            discard h.pickupRows
            var json = newString(pw_world_json(h, nil, 0))
            discard pw_world_json(h, cbuf(json), json.len.int32)
          hashes[calls].add pw_state_hash(h)
          for s in 0..<Seats:
            doAssert pw_seat_orders(h, s.cint, ibuf(o)) == 0
            orders[calls].add o
          if ended: break
        pw_destroy(h)
      check hashes[0].len > 100
      check hashes[0] == hashes[1]
      check orders[0] == orders[1]

  test "pw_seat_items, pw_seat_pickups and pw_pickups agree with the world, the BASIC builtins and pw_world_json":
    var rows, sniperRows, mistRows, radarRows, boostRows, mistLast, radarLast, sniper96, deadRows = 0
    var taken: array[PickupKinds, int]
    for map in ["", "twin-mesas", "crater"]:
      for k in 0..<seeds:
        let seed = int32(4901 + k)
        checkpoint "map '" & map & "' seed " & $seed
        let h = scripted(seed, matchTicks.int32, 49, baseSource, baseSource, map)
        let env = envOf(h)
        var actions: Actions
        for t in 0..<matchTicks:
          # The world before the step, for the pickup-count transitions.
          let tick0 = env.world.tick
          let sniper0 = env.world.sniper
          let mister0 = env.world.misterUntil
          let radar0 = env.world.radarUntil
          var ready0: seq[int32]
          for p in env.world.pickups: ready0.add p.readyAt
          let counts0 = h.pickupCounts
          let ended = h.step(actions)
          template w: untyped = env.world
          # pw_seat_items: the raw-field reference and the BASIC builtins.
          let got = h.items
          for s in 0..<Seats:
            let want = reference(w, s)
            check got[s] == want
            if w.cogs[s].hp <= 0:
              inc deadRows
              for v in got[s]: check v == 0
              continue
            inc rows
            check got[s] == builtins(w, s)
            if got[s][0] == 1: inc sniperRows
            if got[s][0] == 1 and got[s][8] == 96: inc sniper96
            if got[s][1] == 1: inc mistRows
            if got[s][1] == 1 and got[s][2] == 0: inc mistLast
            if got[s][4] == 1: inc radarRows
            if got[s][4] == 1 and got[s][5] == 0: inc radarLast
            if got[s][6] == 1: inc boostRows
            check got[s][2] in 0'f32..1439'f32 and got[s][5] in 0'f32..1439'f32 and got[s][8] in 0'f32..288'f32
          # pw_seat_pickups: kinds 0..4 = pw_seat_equip_stats; 5..7 = the world's transitions; totals = re-arms.
          let counts = h.pickupCounts
          var rearmed: array[PickupKinds, int]
          for i, p in w.pickups:
            if p.readyAt != ready0[i] and p.readyAt > tick0: inc rearmed[ord(p.kind)]
          var gained: array[PickupKinds, int]
          for s in 0..<Seats:
            var eq: array[8, int32]
            check pw_seat_equip_stats(h, s.cint, ibuf(eq)) == 0
            let c = counts[s*PickupKinds ..< (s+1)*PickupKinds]
            check c[0] == eq[3] and c[1] == eq[4] and c[2] == eq[2] and c[3] == eq[0] and c[4] == eq[1]
            var d: array[PickupKinds, int32]
            for kind in 0..<PickupKinds:
              d[kind] = c[kind] - counts0[s*PickupKinds+kind]
              gained[kind] += d[kind].int
            check d[6] == int32(w.sniper[s] and not sniper0[s])
            check d[5] == int32(w.misterUntil[s] == tick0 + MisterTicks.int32 and mister0[s] == 0)
            check d[7] == int32(w.radarUntil[s] == tick0 + RadarTicks.int32)
          for kind in 0..<PickupKinds:
            check gained[kind] == rearmed[kind]
            taken[kind] += gained[kind]
          # pw_pickups: the world's pickups, the BASIC rows a seat sees, and (every 100 ticks) pw_world_json.
          let pr = h.pickupRows
          check pr.len == w.pickups.len*PickupFloats
          check w.pickups.len <= TeamsPickupRows   # every index is a movement-head target (11 + i, i < 32)
          for i, p in w.pickups:
            let o = i*PickupFloats
            check pr[o] == p.pos.x.float32 and pr[o+1] == p.pos.z.float32 and pr[o+2] == ord(p.kind).float32
            check pr[o+3] == float32((p.readyAt <= w.tick).int)
            check pr[o+4] == float32(max(0'i32, p.readyAt - w.tick))
          if t mod 50 == 0:
            beginViews(w)
            for s in 0..<Seats:
              if w.cogs[s].hp <= 0: continue
              let v = seatView(s)
              for i in 0..<w.pickups.len:
                if v.pickupVisible(i) == 0: continue
                let o = i*PickupFloats
                check v.pickupX(i).float32 == pr[o] and v.pickupY(i).float32 == pr[o+1]
                check v.pickupKind(i).float32 == pr[o+2] and pr[o+3] == 1
          if t mod 100 == 0:
            var doc = newString(pw_world_json(h, nil, 0))
            check pw_world_json(h, cbuf(doc), doc.len.int32) == doc.len
            let j = parseJson(doc)
            let tick = j["tick"].getInt
            check tick == w.tick
            check j["pickups"].len == w.pickups.len
            for i, p in j["pickups"].elems:
              let o = i*PickupFloats
              check p["pos"]["x"].getInt.float32 == pr[o] and p["pos"]["z"].getInt.float32 == pr[o+1]
              check ord(parseEnum[PickupKind](p["kind"].getStr)).float32 == pr[o+2]
              check float32((p["readyAt"].getInt <= tick).int) == pr[o+3]
          if ended: break
        pw_destroy(h)
    echo "items: ", rows, " alive rows, ", deadRows, " dead; sniper ", sniperRows, " (", sniper96, " at 96), mister ",
      mistRows, " (", mistLast, " last ticks), radar ", radarRows, " (", radarLast, " last ticks), boosted ", boostRows,
      "; pickups taken by kind ", taken
    check sniperRows > 0 and mistRows > 0 and radarRows > 0 and boostRows > 0
    check taken[5] > 0 and taken[6] > 0 and taken[7] > 0

  test "pickup indices: the island and every generated map fit the movement head; choice 11 + i walks to pw_pickups row i":
    for map in @[""] & @(MapNames):
      if map.startsWith("big-"): continue
      let h = newHandle(7, 600, 49, map)
      let n = pw_pickups(h, nil, 0)
      check n <= TeamsPickupRows
      var late = 0
      for p in envOf(h).world.pickups:
        if p.kind >= misterPickup: inc late
      check late == 6
      pw_destroy(h)
    for map in ["", "twin-mesas"]:
      let probe = newHandle(7, 600, 49, map)
      let rows = probe.pickupRows
      pw_destroy(probe)
      var tested, lateTested = 0
      for i in 0..<rows.len div PickupFloats:
        checkpoint "map '" & map & "' pickup " & $i
        let h = newHandle(7, 600, 49, map)
        let env = envOf(h)
        let target = Point(x: rows[i*PickupFloats].int32, z: rows[i*PickupFloats+1].int32)
        check env.world.pickups[i].pos == target
        # Seat 0 stands a few metres off pickup i, facing it with a clear line, and orders "walk to pickup i"
        # (movement choice 11 + i). The decoder stays put when it does not see the pickup, so a goal on the
        # pickup proves the index.
        var placed = false
        for d in [150'i32, 250, 400]:
          for (ux, uz) in [(1'i32, 0'i32), (-1'i32, 0'i32), (0'i32, 1'i32), (0'i32, -1'i32),
                           (1'i32, 1'i32), (-1'i32, 1'i32), (1'i32, -1'i32), (-1'i32, -1'i32)]:
            let spot = Point(x: target.x + ux*d, z: target.z + uz*d)
            if env.world.blocked(spot): continue
            env.world.cogs[0].pos = spot; env.world.cogs[0].goal = spot; env.world.cogs[0].aim = target
            discard pw_pickups(h, nil, 0)   # binds the handle's rules and map on this thread
            if env.world.canSeePoint(0, target): placed = true; break
          if placed: break
        if not placed:
          pw_destroy(h)
          continue
        var actions: Actions
        actions[0] = int32(11 + i)
        discard h.step(actions)
        check env.world.cogs[0].goal == target
        inc tested
        if rows[i*PickupFloats+2] >= ord(misterPickup).float32: inc lateTested
        pw_destroy(h)
      echo "movement 11 + i on map '", map, "': ", tested, " of ", rows.len div PickupFloats, " pickups (",
        lateTested, " rules-49 items)"
      check lateTested == 6 and tested*2 >= rows.len div PickupFloats

  test "stepped: the sniper's 96-tick shot and 288 under armour; death zeroes the row":
    let h = newHandle(11, 2000, 49)
    let env = envOf(h)
    for s in 0..<Seats: env.world.cogs[s].shield = 0
    env.world.pickups.add Pickup(pos: env.world.cogs[0].pos, kind: sniperPickup)
    h.idle()
    env.world.pickups.setLen(env.world.pickups.len - 1)   # taken; drop it so it never re-arms under the seat
    check h.items[0][0] == 1 and h.items[0][9] == 4800
    check h.pickupCounts[6] == 1
    h.script(0, "shootAt(selfX + 400, selfY)\n")
    var seen: seq[float32]
    for t in 0..<200:
      h.idle()
      seen.add h.items[0][8]
    check 96'f32 in seen and max(seen) == 96
    for t in 0..<100:
      env.world.equipment[0].armor = 3
      h.idle()
      seen.add h.items[0][8]
    check 288'f32 in seen and max(seen) == 288
    # A self-destruct kills seat 0 (not disarmed: ready 1 before); its row is zeros after.
    check h.items[0][11] == 1
    h.script(0, "selfDestruct()\n")
    h.idle()
    check env.world.cogs[0].hp <= 0
    for v in h.items[0]: check v == 0
    pw_destroy(h)

  test "stepped: the mister's minute, heal phase and last tick; the radar's last tick and boost; rules 48 reads none":
    let h = newHandle(12, 4000, 49)
    let env = envOf(h)
    for s in 0..<Seats: env.world.cogs[s].shield = 0
    env.world.pickups.add Pickup(pos: env.world.cogs[0].pos, kind: misterPickup)
    h.idle()
    env.world.pickups.setLen(env.world.pickups.len - 1)   # taken; drop it so it never re-arms under the seat
    var r = h.items[0]
    check r[1] == 1 and r[2] == 1439 and r[3] == 1439 mod 360 and r[7] == 1 and r[11] == 0
    check h.pickupCounts[5] == 1
    var last = false
    for t in 0..<1500:
      h.idle()
      r = h.items[0]
      if r[1] == 0: break
      check r[3] == float32(r[2].int mod 360)
      if r[2] == 0: last = true
    check last and r[1] == 0 and r[7] == 0
    # Radar on seat 2; seat 4 (a teammate) stands beside it and is boosted too.
    let spot = env.world.cogs[2].pos
    env.world.cogs[4].pos = Point(x: spot.x + 60, z: spot.z); env.world.cogs[4].goal = env.world.cogs[4].pos
    env.world.pickups.add Pickup(pos: spot, kind: radarPickup)
    h.idle()
    env.world.pickups.setLen(env.world.pickups.len - 1)   # taken; drop it so it never re-arms under the seat
    r = h.items[2]
    check r[4] == 1 and r[5] == 1439 and r[6] == 1 and r[7] == 1 and h.items[4][6] == 1
    check h.pickupCounts[2*PickupKinds+7] == 1
    last = false
    for t in 0..<1500:
      h.idle()
      r = h.items[2]
      if r[4] == 0: break
      if r[5] == 0: last = true
    check last and r[4] == 0 and r[6] == 0
    pw_destroy(h)
    let old = scripted(12, 1500, 48, baseSource, jevSource)
    for t in 0..<1500:
      old.idle()
      for row in old.items:
        for k in [0, 1, 2, 3, 4, 5, 6, 7, 11]: check row[k] == 0
        check row[9] == 0 or row[9] == 5250
    pw_destroy(old)

  test "pickup counts: pw_reset clears them, pw_world_save / load carries them":
    let h = scripted(4911, 3000, 49, baseSource, baseSource)
    h.idle(2500)
    let counts = h.pickupCounts
    var total = 0
    for c in counts: total += c
    check total > 0
    let size = pw_world_save(h, nil, 0)
    check size > 0
    var blob = newSeq[byte](size)
    check pw_world_save(h, cast[ptr UncheckedArray[byte]](addr blob[0]), size) == size
    let g = newHandle(1, 3000, 49)
    check pw_world_load(g, cast[ptr UncheckedArray[byte]](addr blob[0]), size) == 0
    check g.pickupCounts == counts and g.items == h.items and g.pickupRows == h.pickupRows
    for t in 0..<200:
      h.idle(); g.idle()
      check g.pickupCounts == h.pickupCounts and g.items == h.items
    check pw_reset(h, 4911, 3000) == 0
    for c in h.pickupCounts: check c == 0
    pw_destroy(h); pw_destroy(g)
