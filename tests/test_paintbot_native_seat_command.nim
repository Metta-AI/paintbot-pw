## The per-seat raw-command setter of the native training ABI (pw_set_seat_command):
## arguments; BASIC-equivalent construction (goal verbatim, aim clamped as lookAt clamps);
## next-step-only semantics, the echo through pw_seat_orders and pw_reset; the forbid check
## and head decode skipped for the commanded seat; the fire hold and fire period applied
## only when set; a scripted seat's order replaced; a world whose every seat is driven by
## the commands the production bot loop issued equals that loop, hash for hash; and a
## library whose caller never calls it is untouched. Build with --mm:arc --threads:on
## -d:pwTraining.
import std/[unittest, os]
import polyworld/cli
import ../examples/paintbot/[sim, neural_contract, native_env, bots, oracle]

when not defined(pwTraining): {.error: "the native ABI exists only under -d:pwTraining".}

const Root = currentSourcePath().parentDir.parentDir
const Base = Root / "coworld/paintbot/players/base.bas"
type Buffer = ptr UncheckedArray[cfloat]
template fbuf(a: untyped): Buffer = cast[Buffer](addr a[0])
template ibuf(a: untyped): ptr UncheckedArray[int32] = cast[ptr UncheckedArray[int32]](addr a[0])

proc nine(c: Command): array[9, int32] =
  [c.walk.int32, c.goal.x, c.goal.z, c.shoot.int32, c.aim.x, c.aim.z, c.chargeGrenade.int32, c.sneak.int32, c.direct.int32]

proc setScript(handle: pointer, seat: int, source: string): cint =
  let text = if source.len > 0: cast[ptr UncheckedArray[char]](unsafeAddr source[0]) else: nil
  pw_set_seat_script(handle, seat.cint, text, source.len.int32)

suite "Native raw seat command":
  configureRules(NativeRules)
  test "arguments; construction as BASIC's orders; next step only; echoed; dropped by reset":
    let h = pw_create(7, 600)
    require h != nil
    defer: pw_destroy(h)
    var cmd = [1'i32, 900, 1100, 0, 2000, 1500, 0, 0, 0]
    check pw_set_seat_command(nil, 0, ibuf(cmd)) == -1
    check pw_set_seat_command(h, -1, ibuf(cmd)) == -1
    check pw_set_seat_command(h, Seats.cint, ibuf(cmd)) == -1
    check pw_set_seat_command(h, 0, nil) == -1
    for field in [0, 3, 6, 7, 8]:
      var bad = cmd
      bad[field] = 2
      check pw_set_seat_command(h, 0, ibuf(bad)) == -1
      bad[field] = -1
      check pw_set_seat_command(h, 0, ibuf(bad)) == -1
    var orders: array[10, int32]
    var actions: array[Seats*ActionSizes.len, int32]
    var rewards, terminals: array[Seats, float32]
    # Aim far outside the map clamps exactly as lookAt clamps; the goal is kept verbatim.
    var wild = [1'i32, 99999, -99999, 1, 99999, -99999, 1, 1, 0]
    check pw_set_seat_command(h, 0, ibuf(wild)) == 0
    check pw_seat_orders(h, 0, ibuf(orders)) == 0
    check orders == [0'i32, 0, 0, 0, 0, 0, 0, 0, 0, 0]   # nothing echoed before the step
    check pw_step(h, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
    check pw_seat_orders(h, 0, ibuf(orders)) == 0
    check orders == [1'i32, 99999, -99999, 1, maxX().int32, minZ().int32, 1, 1, 0, 0]
    # Next step without a command: the seat decodes its heads again and the echo clears.
    check pw_step(h, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
    check pw_seat_orders(h, 0, ibuf(orders)) == 0
    check orders == [0'i32, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    # The last call before the step wins; pw_reset drops a pending command.
    check pw_set_seat_command(h, 2, ibuf(wild)) == 0
    check pw_set_seat_command(h, 2, ibuf(cmd)) == 0
    check pw_step(h, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
    check pw_seat_orders(h, 2, ibuf(orders)) == 0
    check orders[0..8] == @cmd
    check pw_set_seat_command(h, 4, ibuf(cmd)) == 0
    check pw_reset(h, 8, 600) == 0
    check pw_step(h, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
    check pw_seat_orders(h, 4, ibuf(orders)) == 0
    check orders == [0'i32, 0, 0, 0, 0, 0, 0, 0, 0, 0]
  test "the commanded seat executes exactly the command: its heads are not decoded and not checked by the forbid":
    var reference = newWorld(11, 600)
    let h = pw_create(11, 600)
    require h != nil
    defer: pw_destroy(h)
    var forbid = [9'i32, 10]
    for slot in 0..<Seats: check pw_set_seat_forbid_objectives(h, slot.cint, ibuf(forbid), 2) == 0
    var actions: array[Seats*ActionSizes.len, int32]
    var rewards, terminals: array[Seats, float32]
    for slot in 0..<Seats: actions[slot*5] = 9   # a forbidden objective on every seat
    check pw_step(h, ibuf(actions), fbuf(rewards), fbuf(terminals)) == -3
    for tick in 0..<300:
      var commands: array[Seats, Command]
      for slot in 0..<Seats:
        let me = reference.cogs[slot]
        commands[slot] = Command(walk: tick mod 7 != 0, goal: point(me.pos.x.int + 400*((slot+tick div 30) mod 3 - 1), me.pos.z.int + 300),
          shoot: tick mod 3 == 0, aim: (if tick mod 5 == 0: Point() else: point(me.pos.x.int + 3000, me.pos.z.int - 700)),
          chargeGrenade: tick mod 40 < 6, sneak: slot mod 4 == 0, direct: tick mod 11 == 0)
        var n = nine(commands[slot])
        require pw_set_seat_command(h, slot.cint, ibuf(n)) == 0
      reference.step(commands)
      require pw_step(h, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0   # forbidden heads ignored
      require pw_state_hash(h) == reference.stateHash()
  test "the fire hold and the fire period apply to a command only when set on the seat":
    proc shootAtMates(w: World): array[Seats, Command] =
      ## Every seat stands and shoots past its first visible teammate, so the hold has work.
      for slot in 0..<Seats:
        let me = w.cogs[slot]
        var aim = point(me.pos.x.int + 2500, me.pos.z.int)
        for other in 0..<Seats:
          if other != slot and team(other) == team(slot) and w.visible(slot, other):
            let o = w.cogs[other].pos
            aim = point(me.pos.x.int + 2*(o.x.int - me.pos.x.int), me.pos.z.int + 2*(o.z.int - me.pos.z.int))
            break
        result[slot] = Command(walk: true, goal: me.pos, shoot: true, aim: aim)
    var finals: array[3, uint32]
    for (i, hold, period) in [(0, false, 1'i32), (1, true, 1'i32), (2, false, 3'i32)]:
      var reference = newWorld(13, 900)
      let h = pw_create(13, 900)
      require h != nil
      for slot in countup(0, Seats-1, 2):
        if hold: check pw_set_seat_fire_hold(h, slot.cint, 1) == 0
        check pw_set_seat_fire_period(h, slot.cint, period) == 0
      var actions: array[Seats*ActionSizes.len, int32]
      var rewards, terminals: array[Seats, float32]
      var held = 0
      while reference.winner == -1 and reference.tick < 600:
        var commands = shootAtMates(reference)
        for slot in 0..<Seats:
          var n = nine(commands[slot])
          require pw_set_seat_command(h, slot.cint, ibuf(n)) == 0
        for slot in countup(0, Seats-1, 2):
          if hold and reference.holdFire(slot, commands[slot]): inc held
        reference.step(commands)
        require pw_step(h, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
        if period == 1: require pw_state_hash(h) == reference.stateHash()
      finals[i] = pw_state_hash(h)
      var reported = 0
      for slot in 0..<Seats: reported += pw_seat_fire_held(h, slot.cint)
      checkpoint "hold " & $hold & " period " & $period
      check reported == held
      if hold: check held > 0
      pw_destroy(h)
    check finals[0] != finals[1] and finals[0] != finals[2]   # both knobs acted when set
  test "a scripted seat's order is replaced for the commanded step, and echoed":
    resetOracle()
    let h = pw_create(17, 600)
    require h != nil
    defer: pw_destroy(h)
    let source = readFile(Base)
    for slot in 0..<Seats: check setScript(h, slot, source) == 0
    var actions: array[Seats*ActionSizes.len, int32]
    var rewards, terminals: array[Seats, float32]
    var orders: array[10, int32]
    for tick in 0..<5: require pw_step(h, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
    var cmd = [1'i32, 1234, 2345, 0, 3000, 2000, 0, 1, 0]
    check pw_set_seat_command(h, 3, ibuf(cmd)) == 0
    check pw_step(h, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
    check pw_seat_orders(h, 3, ibuf(orders)) == 0
    check orders == [1'i32, 1234, 2345, 0, 3000, 2000, 0, 1, 0, 1]
    check pw_seat_script_status(h, 3, nil, 0) == 1
    check pw_step(h, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
    check pw_seat_orders(h, 3, ibuf(orders)) == 0
    check orders[9] == 1 and orders[0..8] != @cmd   # the script's own order again
  test "every seat driven by the production bot loop's commands equals that loop, hash for hash, both contracts":
    for (seed, contract) in [(21'i32, 1'i32), (22'i32, 2'i32), (23'i32, 2'i32)]:
      resetOracle()
      var w = newWorld(seed, 2400)
      let players = loadBots(@[BotGroup(path: Base, count: Seats)])
      let h = pw_create(seed, 2400)
      require h != nil
      check pw_set_action_contract(h, contract) == 0
      var actions: array[Seats*ActionSizes.len, int32]
      var rewards, terminals: array[Seats, float32]
      var orders: array[10, int32]
      var steps = 0
      while w.winner == -1 and w.tick < w.endTick:
        let commands = players.decide(w)
        deliverSpeech(w)
        for slot in 0..<Seats:
          var n = nine(commands[slot])
          require pw_set_seat_command(h, slot.cint, ibuf(n)) == 0
        w.step(commands)
        require pw_step(h, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
        require pw_state_hash(h) == w.stateHash()
        for slot in 0..<Seats:
          require pw_seat_orders(h, slot.cint, ibuf(orders)) == 0
          require orders[0..8] == @(nine(commands[slot]))
        inc steps
      for slot in 0..<Seats: require not players[slot].failed
      checkpoint "seed " & $seed & " steps " & $steps
      check steps > 500
      pw_destroy(h)
  test "a caller that never sets a command is byte-identical to the decoded path":
    let a = pw_create(31, 600)
    let b = pw_create(31, 600)
    require a != nil and b != nil
    defer:
      pw_destroy(a)
      pw_destroy(b)
    var reference = newWorld(31, 600)
    var actions: array[Seats*ActionSizes.len, int32]
    var rewards, terminals: array[Seats, float32]
    var orders: array[10, int32]
    while reference.winner == -1 and reference.tick < reference.endTick:
      for slot in 0..<Seats:
        let o = slot*ActionSizes.len
        actions[o] = int32(1 + (slot + reference.tick.int div 60) mod 10)
        actions[o+1] = int32(17 + (reference.tick.int div 9 + slot) mod 8)
        actions[o+2] = int32(reference.tick mod 3 == 0)
      var commands: array[Seats, Command]
      for slot in 0..<Seats:
        let o = slot*ActionSizes.len
        commands[slot] = reference.decodeActions(slot, actions.toOpenArray(o, o+ActionSizes.len-1))
      reference.step(commands)
      require pw_step(a, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
      require pw_step(b, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
      require pw_state_hash(a) == reference.stateHash() and pw_state_hash(b) == reference.stateHash()
      for slot in 0..<Seats:
        require pw_seat_orders(a, slot.cint, ibuf(orders)) == 0
        require orders == [0'i32, 0, 0, 0, 0, 0, 0, 0, 0, 0]
