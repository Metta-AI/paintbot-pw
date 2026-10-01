## BASIC seats inside the native training environment: a scripted seat issues orders and
## captures, the scripted handle matches the in-process production bot loop hash for hash,
## an unscripted handle matches the reference engine exactly, and errors disable a seat
## the way the host does, and the mapping-ceiling diagnostics (pw_script_decide /
## pw_set_seat_override) reproduce exact scripted play with mask 0. Build with --mm:arc --threads:on -d:pwTraining.
import std/[unittest, os]
import polyworld/[cli, basic]
import ../examples/paintbot/[sim, neural_contract, native_env, bots]

when not defined(pwTraining): {.error: "native scripts exist only under -d:pwTraining".}

const Root = currentSourcePath().parentDir.parentDir
const Base = Root / "coworld/paintbot/players/base.bas"
const DecoderSource = staticRead("../examples/paintbot/players/neural_decode.bas")
type Buffer = ptr UncheckedArray[cfloat]
template fbuf(a: untyped): Buffer = cast[Buffer](addr a[0])
template ibuf(a: untyped): ptr UncheckedArray[int32] = cast[ptr UncheckedArray[int32]](addr a[0])

proc setScript(handle: pointer, seat: int, source: string): cint =
  let text = if source.len > 0: cast[ptr UncheckedArray[char]](unsafeAddr source[0]) else: nil
  pw_set_seat_script(handle, seat.cint, text, source.len.int32)

suite "Native BASIC seats":
  configureRules(NativeRules)
  let baseSource = readFile(Base)
  test "a scripted seat issues orders and its team captures; unscripted seats idle":
    let handle = pw_create(2026, 4800)
    require handle != nil
    for slot in 0..<Seats:
      if team(slot) == 0: check setScript(handle, slot, baseSource) == 0
    var actions: array[LegacySeats*ActionSizes.len, int32] # All zeros: unscripted seats idle.
    var rewards, terminals: array[LegacySeats, float32]
    var results: array[8, float32]
    var orders: array[10, int32]
    var walked = 0
    var tick = 0
    while tick < 4800 and terminals[0] == 0:
      require pw_step(handle, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
      inc tick
      check pw_seat_orders(handle, 0, ibuf(orders)) == 0
      check orders[9] == 1
      if orders[0] == 1: inc walked
      check pw_seat_orders(handle, 1, ibuf(orders)) == 0
      check orders == [0'i32, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    check walked > tick div 2
    check pw_results(handle, fbuf(results)) == 0
    check results[6] > results[7] # Ember (scripted) holds more hearts than idle Azure.
    check results[6] >= 3
    for slot in 0..<Seats:
      check pw_seat_script_status(handle, slot.cint, nil, 0) == (if team(slot) == 0: 1 else: 0)
    pw_destroy(handle)
  test "scripted handle matches the production bot loop hash for hash, across a reset":
    for seed in [4'i32, 5, 8]:
      # Reference: the game's own loop (decide, deliverSpeech, step) with file seats.
      resetOracle()
      var w = newWorld(seed, 720)
      let players = loadBots(@[BotGroup(path: Base, count: Seats)])
      var expected: seq[uint32]
      while w.tick < 720 and w.winner == -1:
        let commands = players.decide(w)
        deliverSpeech(w)
        w.step(commands)
        expected.add w.stateHash()
      let handle = pw_create(seed, 720)
      require handle != nil
      for slot in 0..<Seats: check setScript(handle, slot, baseSource) == 0
      var actions: array[LegacySeats*ActionSizes.len, int32]
      var rewards, terminals: array[LegacySeats, float32]
      for pass in 0..1:
        if pass == 1: check pw_reset(handle, seed, 720) == 0
        for hash in expected:
          require pw_step(handle, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
          require pw_state_hash(handle) == hash
        for slot in 0..<Seats: check pw_seat_script_status(handle, slot.cint, nil, 0) == 1
      pw_destroy(handle)
  test "an unscripted handle still matches the reference engine (the reference decoder script) exactly":
    var reference = newWorld(77, 480)
    var seats: seq[Bot]
    for slot in 0..<Seats: seats.add loadDecoderBot(DecoderSource, slot, ObservationContractTeamsView1Hash, acTeamsView1)
    let handle = pw_create(77, 480)
    require handle != nil
    var actions: array[LegacySeats*ActionSizes.len, int32]
    var rewards, terminals: array[LegacySeats, float32]
    while reference.winner == -1 and reference.tick < reference.endTick:
      for slot in 0..<Seats:
        let o = slot*ActionSizes.len
        actions[o] = int32(1+(slot div 2) mod 10)
        actions[o+1] = int32(17+(reference.tick.int div 24+slot) mod 8)
        actions[o+2] = int32(reference.tick mod 3 == 0)
        for head in 0..<ActionSizes.len: seats[slot].neural.fedChoices[head] = actions[o+head]
        seats[slot].neural.choicesFed = true
      reference.step(decideSeats(seats, reference))
      require pw_step(handle, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
      require pw_state_hash(handle) == reference.stateHash()
    pw_destroy(handle)
  test "errors disable a seat like the host: compile failure idles, budget overrun disables":
    let handle = pw_create(3, 240)
    require handle != nil
    var message: array[256, char]
    check setScript(handle, 0, "walkTo(") == 1
    check pw_seat_script_status(handle, 0, cast[ptr UncheckedArray[char]](addr message[0]), 256) == 2
    check ($cast[cstring](addr message[0])).len > 0
    check setScript(handle, 2, "while 1 = 1\n  x = x + 1\nwend\n") == 0
    check pw_seat_script_status(handle, 2, nil, 0) == 1
    var actions: array[LegacySeats*ActionSizes.len, int32]
    var rewards, terminals: array[LegacySeats, float32]
    require pw_step(handle, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
    check pw_seat_script_status(handle, 2, cast[ptr UncheckedArray[char]](addr message[0]), 256) == 3
    check ($cast[cstring](addr message[0])).len > 0
    var orders: array[10, int32]
    check pw_seat_orders(handle, 2, ibuf(orders)) == 0
    check orders[0] == 0 and orders[9] == 1
    check setScript(handle, 0, "") == 0
    check pw_seat_script_status(handle, 0, nil, 0) == 0
    pw_destroy(handle)
  test "mask 0 with pw_script_decide reproduces exact scripted play; a masked head follows the caller":
    let baseSource = readFile(Base)
    for seed in [4'i32, 8]:
      var expected: seq[uint32]
      block plain:
        let handle = pw_create(seed, 600)
        require handle != nil
        for slot in 0..<Seats: check setScript(handle, slot, baseSource) == 0
        var actions: array[LegacySeats*ActionSizes.len, int32]
        var rewards, terminals: array[LegacySeats, float32]
        while terminals[0] == 0 and expected.len < 600:
          require pw_step(handle, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
          expected.add pw_state_hash(handle)
        pw_destroy(handle)
      block preDecided:
        let handle = pw_create(seed, 600)
        require handle != nil
        for slot in 0..<Seats:
          check setScript(handle, slot, baseSource) == 0
          check pw_set_seat_override(handle, slot.cint, 0) == 0
        check pw_set_seat_override(handle, 0, 64) == -1
        var actions: array[LegacySeats*ActionSizes.len, int32]
        var rewards, terminals: array[LegacySeats, float32]
        var orders: array[10, int32]
        for hash in expected:
          check pw_script_decide(handle) == 1
          check pw_script_decide(handle) == 0 # once per tick
          check pw_seat_orders(handle, 0, ibuf(orders)) == 0
          check orders[9] == 1
          require pw_step(handle, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
          require pw_state_hash(handle) == hash
        pw_destroy(handle)
      block masked:
        # Team 0's shoot and grenade heads from the caller (never fire): the world diverges and the
        # scripted team lands no hits while its orders are still reported.
        let handle = pw_create(seed, 600)
        require handle != nil
        for slot in 0..<Seats:
          check setScript(handle, slot, baseSource) == 0
          if team(slot) == 0: check pw_set_seat_override(handle, slot.cint, 12) == 0
        var actions: array[LegacySeats*ActionSizes.len, int32]
        var rewards, terminals: array[LegacySeats, float32]
        var orders: array[10, int32]
        var stats: array[LegacySeats*8, int32]
        var diverged = false
        var shootOrders = 0
        for hash in expected:
          require pw_step(handle, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
          if pw_state_hash(handle) != hash: diverged = true
          check pw_seat_orders(handle, 0, ibuf(orders)) == 0
          if orders[3] == 1: inc shootOrders
          if terminals[0] != 0: break
        check pw_seat_stats(handle, ibuf(stats)) == 0
        var hitsTeam0 = 0
        for slot in 0..<Seats:
          if team(slot) == 0: hitsTeam0 += stats[slot*8+2]
        check shootOrders > 0
        check hitsTeam0 == 0
        check diverged
        pw_destroy(handle)
