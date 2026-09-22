## The decoder fire hold through the native training ABI: arguments and reset semantics,
## a hold-on handle against the reference engine applying neural_contract.holdFire after
## the shared decoder (hash for hash, holds counted), hold off byte-identical to a fresh
## handle, candidates untouched, and scripted seats: a shooting script with a teammate in
## front deals no friendly-fire damage with the hold on, and base.bas seats under the
## hold match the production bot loop with the same hold applied.
## Build with --mm:arc --threads:on -d:pwTraining.
import std/[unittest, os]
import polyworld/cli
import ../examples/paintbot/[sim, neural_contract, native_env, bots, oracle]

when not defined(pwTraining): {.error: "the native ABI exists only under -d:pwTraining".}

const Root = currentSourcePath().parentDir.parentDir
const Base = Root / "coworld/paintbot/players/base.bas"
type Buffer = ptr UncheckedArray[cfloat]
template fbuf(a: untyped): Buffer = cast[Buffer](addr a[0])
template ibuf(a: untyped): ptr UncheckedArray[int32] = cast[ptr UncheckedArray[int32]](addr a[0])

proc setScript(handle: pointer, seat: int, source: string): cint =
  let text = if source.len > 0: cast[ptr UncheckedArray[char]](unsafeAddr source[0]) else: nil
  pw_set_seat_script(handle, seat.cint, text, source.len.int32)

proc mixedActions(w: World, actions: var array[Seats*ActionSizes.len, int32], seed: int) =
  ## Identity aims at the nearest apparent enemy, else a changing compass aim; heart
  ## objectives; fire, grenade and sneak on schedules (the contract v2 suite's policy).
  for slot in 0..<Seats:
    let o = slot*ActionSizes.len
    actions[o] = int32(1+(slot div 2+seed) mod 10)
    actions[o+1] = int32(17+(w.tick.int div 24+slot) mod 8)
    let bodies = w.observedBodies(slot)
    var best = high(int64)
    for identity, body in bodies:
      if body < 0 or w.observedTeam(slot, body) == team(slot): continue
      let d = distance2(w.cogs[slot].pos, w.cogs[body].pos)
      if d < best:
        best = d
        actions[o+1] = int32(identity+1)
    actions[o+2] = int32(w.tick mod 3 == 0)
    actions[o+3] = int32(w.tick mod 48 < 12)
    actions[o+4] = int32(slot mod 3 == 0)

proc openGround(w: World, a, b: Point): bool =
  not w.blocked(a) and not w.blocked(b) and w.trenchAt(a) < 0 and w.trenchAt(b) < 0 and w.lineClear(a, b)

proc lane(w: var World, shooter, mate, target: int): (Point, Point, Point) =
  ## Shooter, teammate 600 ahead, target 1200 ahead on one open east-west line; everyone
  ## else along the far edge.
  var s, m, t: Point
  var found = false
  for slot in 0..<Seats:
    if slot notin [shooter, mate, target]:
      w.cogs[slot].pos = point(200 + slot*80, maxZ() - 60)
  for gz in countup(600, 3200, 200):
    for gx in countup(0, 5000, 200):
      s = point(gx, gz); m = point(gx + 600, gz); t = point(gx + 1200, gz)
      if not w.openGround(s, t) or w.blocked(m) or w.trenchAt(m) >= 0: continue
      w.cogs[shooter].pos = s; w.cogs[shooter].aim = t
      w.cogs[mate].pos = m; w.cogs[mate].aim = t
      w.cogs[target].pos = t
      if w.visible(shooter, target) and w.visible(shooter, mate): found = true
      if found: break
    if found: break
  doAssert found
  for slot in 0..<Seats:
    w.cogs[slot].goal = w.cogs[slot].pos
    w.cogs[slot].shield = 0
    w.equipment[slot].armor = 0
  (s, m, t)

suite "Native decoder fire hold":
  configureRules(NativeRules)
  test "arguments, defaults, reset semantics":
    let handle = pw_create(1, 240)
    require handle != nil
    for slot in 0..<Seats: check pw_seat_fire_held(handle, slot.cint) == 0
    check pw_set_seat_fire_hold(nil, 0, 1) == -1
    check pw_set_seat_fire_hold(handle, -1, 1) == -1
    check pw_set_seat_fire_hold(handle, Seats.cint, 1) == -1
    check pw_set_seat_fire_hold(handle, 0, 2) == -1
    check pw_seat_fire_held(nil, 0) == -1
    check pw_seat_fire_held(handle, Seats.cint) == -1
    check pw_set_seat_fire_hold(handle, 0, 1) == 0
    check pw_set_seat_fire_hold(handle, 0, 0) == 0
    check pw_set_seat_fire_hold(handle, 0, 1) == 0
    check pw_reset(handle, 2, 240) == 0
    check pw_seat_fire_held(handle, 0) == 0
    pw_destroy(handle)
  test "a hold-on handle matches the reference engine applying holdFire after the shared decoder; holds happen":
    var totalHeld = 0
    for seed in [0'i32, 1, 2]:
      var reference = newWorld(seed+61, 720)
      let handle = pw_create(seed+61, 720)
      require handle != nil
      # Team 0 under the hold, team 1 plain.
      for slot in countup(0, Seats-1, 2): check pw_set_seat_fire_hold(handle, slot.cint, 1) == 0
      var actions: array[Seats*ActionSizes.len, int32]
      var commands: array[Seats, Command]
      var rewards, terminals: array[Seats, float32]
      var held: array[Seats, int]
      for pass in 0..1:
        if pass == 1:
          reference = newWorld(seed+61, 720)
          check pw_reset(handle, seed+61, 720) == 0
          for slot in 0..<Seats:
            check pw_seat_fire_held(handle, slot.cint) == 0 # the count belongs to the match
            held[slot] = 0
        while reference.winner == -1 and reference.tick < reference.endTick:
          mixedActions(reference, actions, seed.int)
          for slot in 0..<Seats:
            let o = slot*ActionSizes.len
            commands[slot] = reference.decodeActions(slot, actions.toOpenArray(o, o+ActionSizes.len-1),
              reference.observedBodies(slot))
            if slot mod 2 == 0 and reference.holdFire(slot, commands[slot]): inc held[slot]
          reference.step(commands)
          require pw_step(handle, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
          require pw_state_hash(handle) == reference.stateHash()
        for slot in 0..<Seats:
          check pw_seat_fire_held(handle, slot.cint) == held[slot].cint
          if slot mod 2 == 1: check held[slot] == 0
          totalHeld += held[slot]
      pw_destroy(handle)
    check totalHeld > 0
  test "hold off is byte-identical to a fresh handle; candidates are untouched by the hold":
    let plain = pw_create(9, 480)
    let toggled = pw_create(9, 480)
    require plain != nil and toggled != nil
    for slot in 0..<Seats:
      check pw_set_seat_fire_hold(toggled, slot.cint, 1) == 0
      check pw_set_seat_fire_hold(toggled, slot.cint, 0) == 0
    var reference = newWorld(9, 480)
    var actions: array[Seats*ActionSizes.len, int32]
    var rewards, terminals: array[Seats, float32]
    var goalsA, goalsB: array[ActionSizes[0]*2, int32]
    var aimsA, aimsB: array[ActionSizes[1]*2, int32]
    while reference.winner == -1 and reference.tick < reference.endTick:
      mixedActions(reference, actions, 9)
      for slot in 0..<Seats:
        check pw_action_candidates(plain, slot.cint, actions[slot*5], actions[slot*5+4], ibuf(goalsA), ibuf(aimsA)) == 0
        check pw_set_seat_fire_hold(toggled, slot.cint, 1) == 0
        check pw_action_candidates(toggled, slot.cint, actions[slot*5], actions[slot*5+4], ibuf(goalsB), ibuf(aimsB)) == 0
        check pw_set_seat_fire_hold(toggled, slot.cint, 0) == 0
        require goalsA == goalsB and aimsA == aimsB
      require pw_step(plain, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
      require pw_step(toggled, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
      require pw_state_hash(plain) == pw_state_hash(toggled)
      var commands: array[Seats, Command]
      for slot in 0..<Seats:
        let o = slot*ActionSizes.len
        commands[slot] = reference.decodeActions(slot, actions.toOpenArray(o, o+ActionSizes.len-1),
          reference.observedBodies(slot))
      reference.step(commands)
      require pw_state_hash(plain) == reference.stateHash()
    for slot in 0..<Seats: check pw_seat_fire_held(toggled, slot.cint) == 0
    pw_destroy(plain)
    pw_destroy(toggled)
  test "a scripted seat with a teammate in front deals no friendly-fire damage under the hold":
    resetOracle()
    var w = newWorld(2026, 2400)
    let shooter = 0
    let mate = 2
    let target = 1
    let (s, m, t) = w.lane(shooter, mate, target)
    discard s; discard m
    require w.cogs[shooter].cooldown == 0 and w.equipment[shooter].windup == 0
    require not w.equipment[shooter].sprayCan
    # The production interpreter drives the seat: it shoots at the enemy's position.
    var players: array[Seats, Bot]
    players[shooter] = loadScriptBot("shootAt(" & $t.x & ", " & $t.z & ")\n", shooter)
    for (name, hold, mateHp) in [("plain", false, 2'i32), ("held", true, 3'i32)]:
      var trial = w
      var stats: CombatTelemetry
      for slot in 0..<Seats: stats[slot] = SeatStats(firstFriendlyFireTick: -1)
      var holds = 0
      for tick in 0..GunWindupTicks:
        var commands = players.decide(trial)
        require not players[shooter].failed
        require commands[shooter].shoot and commands[shooter].aim == t
        if hold and trial.holdFire(shooter, commands[shooter]): inc holds
        combatTelemetry = addr stats
        try: trial.step(commands)
        finally: combatTelemetry = nil
      checkpoint name
      check trial.cogs[mate].hp == mateHp
      check trial.cogs[target].hp == 3
      check stats[shooter].damageDealtTeam == 3 - mateHp
      check holds == (if hold: GunWindupTicks+1 else: 0)
  test "scripted seats under the hold match the production bot loop with the same hold applied":
    # A naive shooter (no line-of-fire guard of its own) so the hold has work to do: it
    # shoots at every visible enemy's position while walking to the enemy heart. base.bas
    # is run the same way for parity; it carries its own guard (base.bas "Hold fire when a
    # visible teammate stands in the line", across < 95) so the hold rarely, if ever, fires
    # for it, which is why the count assertion is on the naive script only.
    const Naive = """
i = 0
while i < 16
  if i <> selfId and i mod 2 <> selfTeam and visible(i) then
    shootAt(playerX(i), playerY(i))
  end if
  i = i + 1
wend
walkTo(heartX, heartY)
"""
    let naivePath = getTempDir() / "paintbot-fire-hold-naive.bas"
    writeFile(naivePath, Naive)
    defer: removeFile(naivePath)
    for (path, seeds, ticks, mustHold) in [(naivePath, @[3'i32, 5], 1200, true), (Base, @[4'i32], 1200, false)]:
      let source = readFile(path)
      var totalHeld = 0
      for seed in seeds:
        resetOracle()
        var w = newWorld(seed, ticks.int32)
        let players = loadBots(@[BotGroup(path: path, count: Seats)])
        var expected: seq[uint32]
        var held: array[Seats, int]
        while w.tick < ticks and w.winner == -1:
          var commands = players.decide(w)
          deliverSpeech(w)
          for slot in countup(0, Seats-1, 2):
            if w.holdFire(slot, commands[slot]): inc held[slot]
          w.step(commands)
          expected.add w.stateHash()
        for slot in 0..<Seats: require not players[slot].failed
        let handle = pw_create(seed, ticks.int32)
        require handle != nil
        for slot in 0..<Seats: check setScript(handle, slot, source) == 0
        for slot in countup(0, Seats-1, 2): check pw_set_seat_fire_hold(handle, slot.cint, 1) == 0
        var actions: array[Seats*ActionSizes.len, int32]
        var rewards, terminals: array[Seats, float32]
        for hash in expected:
          require pw_step(handle, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
          require pw_state_hash(handle) == hash
        for slot in 0..<Seats:
          check pw_seat_script_status(handle, slot.cint, nil, 0) == 1
          check pw_seat_fire_held(handle, slot.cint) == held[slot].cint
          if slot mod 2 == 1: check held[slot] == 0
          totalHeld += held[slot]
        pw_destroy(handle)
      checkpoint path
      if mustHold: check totalHeld > 0
