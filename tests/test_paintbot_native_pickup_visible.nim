## pw_seat_pickup_visible (training library only): per-seat bitsets of the pickups each seat sees, by the ONE test
## (SeatView.pickupVisible = seat_view's pickupSeen) BASIC's pickupVisible / pickupKind and teams.view.1 / 1i's pickup rows use. Over scripted
## rules-49 base.bas matches (the island, twin-mesas and crater, own and team vision), every tick and every seat:
## - each bit equals BASIC's pickupVisible(i) on that seat's SeatView;
## - the visible rules-49 pickups (kinds 5..7) in index order equal the late-pickup rows teams.view.1i's item block
##   (encodeItemBlock) writes for the seat (visible flag, one-hot kind, index / 31);
## - a dead seat's bits are all 0;
## and calling it every tick changes nothing: the state hash sequence equals a match that never calls it.
## Bad arguments, sizing (words 0) and truncation (bits past 32 x words not written) are checked too.
## Build with --mm:arc --threads:on -d:pwTraining -d:headless.
import std/[unittest, os, importutils]
import ../examples/paintbot/[sim, neural_contract, native_env, seat_view]

when not defined(pwTraining): {.error: "pw_seat_pickup_visible exists only under -d:pwTraining".}

privateAccess(NativeEnv)
const Root = currentSourcePath().parentDir.parentDir
type Buffer = ptr UncheckedArray[cfloat]
template fbuf(a: untyped): Buffer = cast[Buffer](addr a[0])
template ibuf(a: untyped): ptr UncheckedArray[int32] = cast[ptr UncheckedArray[int32]](addr a[0])
template ubuf(a: untyped): ptr UncheckedArray[uint32] = cast[ptr UncheckedArray[uint32]](addr a[0])

proc mapIndex(name: string): cint =
  if name == "": return -1
  for i, m in MapNames:
    if m == name: return i.cint
  doAssert false, "unknown map " & name

proc scripted(seed, ticks: int32, map: string, teamVision: bool): pointer =
  result = pw_create(seed, ticks)
  doAssert result != nil
  doAssert pw_set_rules(result, 49) == 0
  doAssert pw_set_map(result, mapIndex(map)) == 0
  cast[ptr NativeEnv](result).vision = teamVision
  cast[ptr NativeEnv](result).nextVision = teamVision
  doAssert pw_reset(result, seed, ticks) == 0
  let base = readFile(Root / "coworld/paintbot/players/base.bas")
  for slot in 0..<Seats:
    doAssert pw_set_seat_script(result, slot.cint, cast[ptr UncheckedArray[char]](unsafeAddr base[0]), base.len.int32) == 0

suite "pw_seat_pickup_visible":
  test "bad arguments, sizing and truncation":
    let h = scripted(4911, 400, "twin-mesas", false)
    check pw_seat_pickup_visible(nil, nil, 0) == -1
    check pw_seat_pickup_visible(h, nil, -1) == -1
    check pw_seat_pickup_visible(h, nil, 1) == -1
    let n = pw_seat_pickup_visible(h, nil, 0)
    check n == cast[ptr NativeEnv](h).world.pickups.len and n > 0
    var one = newSeq[uint32](Seats)
    check pw_seat_pickup_visible(h, ubuf(one), 1) == n   # only pickups 0..31 written, still returns the count
    pw_destroy(h)

  test "bits == BASIC pickupVisible == teams.view.1i late-pickup rows; calling it changes nothing":
    const Ticks = 3000'i32
    var cases, seen, lateSeen, deadRows: int
    for (seed, map, team) in [(4921'i32, "", false), (4922'i32, "twin-mesas", false), (4923'i32, "crater", true),
        (4924'i32, "twin-mesas", true)]:
      let a = scripted(seed, Ticks, map, team)     # calls the export every tick
      let b = scripted(seed, Ticks, map, team)     # never calls it
      let env = cast[ptr NativeEnv](a)
      let n = pw_seat_pickup_visible(a, nil, 0)
      let words = max(1, (n + 31) div 32)
      var bitsBuf = newSeq[uint32](Seats*words)
      var actions: array[LegacySeats*ActionSizes.len, int32]
      var rewards, terminals: array[LegacySeats, float32]
      var itemBlock: array[ItemBlockWidth, float32]
      for t in 0..<Ticks:
        doAssert pw_seat_pickup_visible(a, ubuf(bitsBuf), words.int32) == n
        beginViews(env.world)
        for slot in 0..<Seats:
          let v = seatView(slot)
          var late: seq[int]
          for i in 0..<n:
            let bit = (bitsBuf[slot*words + i div 32] shr (i mod 32)) and 1
            check bit.int32 == v.pickupVisible(i)
            inc cases
            if bit == 1:
              inc seen
              if env.world.pickups[i].kind.int32 >= FirstLatePickupKind: late.add i
          if env.world.cogs[slot].hp <= 0:
            inc deadRows
            for k in 0..<words: check bitsBuf[slot*words + k] == 0
          encodeItemBlock(v, itemBlock)
          for r in 0..<LatePickupRows:
            let o = LatePickupOffset + r*LatePickupWidth
            if r < late.len:
              let i = late[r]
              inc lateSeen
              check itemBlock[o] == 1 and itemBlock[o+6] == float32(i) / 31
              check itemBlock[o+3 + int(env.world.pickups[i].kind.int32 - FirstLatePickupKind)] == 1
            else:
              check itemBlock[o] == 0
        doAssert pw_step(a, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
        var t2: array[LegacySeats, float32]
        doAssert pw_step(b, ibuf(actions), fbuf(rewards), fbuf(t2)) == 0
        check pw_state_hash(a) == pw_state_hash(b)
        if terminals[0] == 1: break
      pw_destroy(a); pw_destroy(b)
    check seen > 0 and lateSeen > 0 and deadRows > 0
    echo "pickup visibility: ", cases, " seat-pickup cases, ", seen, " seen (", lateSeen, " rules-49 late rows), ",
      deadRows, " dead seat-ticks"
