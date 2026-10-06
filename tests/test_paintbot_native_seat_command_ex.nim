## pw_set_seat_command_ex / pw_seat_orders_ex (training library only): the rules-49 self-destruct
## order in the raw-command harness. pw_set_seat_command's nine fields cannot carry Command.selfDestruct,
## so a rules-49 recording in which a cog self-destructs cannot be replayed through the library by
## command; the _ex pair adds that one field and nothing else.
## - bad arguments are refused;
## - self_destruct 0 is byte-identical to pw_set_seat_command (hashes and echoes, every tick);
## - a scripted rules-49 match in which a BASIC seat calls selfDestruct() is saved as a real .replay
##   (game.saveRecording), re-simulated through game.advance (hash-checked every frame), and replayed
##   by command through a fresh library handle with pw_set_seat_command_ex: every frame's state hash
##   and every order echo (pw_seat_orders_ex, self_destruct included) match. The same replay through
##   pw_set_seat_command diverges exactly on the first self-destruct frame.
## Build with --mm:arc --threads:on -d:pwTraining -d:headless.
import std/[unittest, os, importutils]
import ../examples/paintbot/[sim, game, neural_contract, native_env]

when not defined(pwTraining): {.error: "pw_set_seat_command_ex exists only under -d:pwTraining".}

privateAccess(NativeEnv)
const Root = currentSourcePath().parentDir.parentDir
const Base = Root / "coworld/paintbot/players/base.bas"
type Buffer = ptr UncheckedArray[cfloat]
template fbuf(a: untyped): Buffer = cast[Buffer](addr a[0])
template ibuf(a: untyped): ptr UncheckedArray[int32] = cast[ptr UncheckedArray[int32]](addr a[0])

# The bomber: base.bas, then a self-destruct whenever a visible foe is inside the blast (270).
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

proc ten(c: Command): array[10, int32] =
  [c.walk.int32, c.goal.x, c.goal.z, c.shoot.int32, c.aim.x, c.aim.z, c.chargeGrenade.int32,
   c.sneak.int32, c.direct.int32, c.selfDestruct.int32]

proc newHandle(seed, ticks: int32): pointer =
  result = pw_create(seed, ticks)
  doAssert result != nil
  doAssert pw_set_rules(result, 49) == 0
  doAssert pw_reset(result, seed, ticks) == 0

suite "pw_set_seat_command_ex":
  test "bad arguments":
    let h = newHandle(5, 200)
    var c: array[10, int32]
    check pw_set_seat_command_ex(nil, 0, ibuf(c)) == -1
    check pw_set_seat_command_ex(h, 0, nil) == -1
    check pw_set_seat_command_ex(h, -1, ibuf(c)) == -1
    check pw_set_seat_command_ex(h, Seats.cint, ibuf(c)) == -1
    c[9] = 2
    check pw_set_seat_command_ex(h, 0, ibuf(c)) == -1
    c[9] = 0; c[3] = 2
    check pw_set_seat_command_ex(h, 0, ibuf(c)) == -1
    c[3] = 0
    check pw_set_seat_command_ex(h, 0, ibuf(c)) == 0
    var o: array[11, int32]
    check pw_seat_orders_ex(nil, 0, ibuf(o)) == -1
    check pw_seat_orders_ex(h, Seats.cint, ibuf(o)) == -1
    check pw_seat_orders_ex(h, 0, nil) == -1
    pw_destroy(h)

  test "a rules-49 self-destruct match: .replay + game.advance, and command replay with _ex (not without)":
    const Seed = 4901'i32
    const Ticks = 14400'i32
    let base = readFile(Base)
    let bomber = base & BomberTail
    # 1. The scripted match: blue (odd seats) are bombers, red plays base.bas.
    let a = newHandle(Seed, Ticks)
    for slot in 0..<Seats:
      let source = if slot mod 2 == 1: bomber else: base
      doAssert pw_set_seat_script(a, slot.cint, cast[ptr UncheckedArray[char]](unsafeAddr source[0]),
        source.len.int32) == 0
    let env = cast[ptr NativeEnv](a)
    var rec = Recording(seed: Seed, endTick: env.world.endTick, glory: env.glory, seats: Seats.int32)
    for slot in 0..<Seats: rec.names.add (if slot mod 2 == 1: "bomber" else: "base")
    var actions: array[LegacySeats*ActionSizes.len, int32]
    var rewards, terminals: array[LegacySeats, float32]
    var echoes: seq[seq[array[11, int32]]]
    var firstSd = -1
    for t in 0..<Ticks:
      doAssert pw_step(a, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
      var frame = Frame(commands: env.scriptOrders[0..<Seats], hash: pw_state_hash(a))
      var row: seq[array[11, int32]]
      for slot in 0..<Seats:
        var o: array[11, int32]
        doAssert pw_seat_orders_ex(a, slot.cint, ibuf(o)) == 0
        var o10: array[10, int32]
        doAssert pw_seat_orders(a, slot.cint, ibuf(o10)) == 0
        for k in 0..<10: doAssert o[k] == o10[k]          # _ex = pw_seat_orders + one field
        doAssert o[10] == frame.commands[slot].selfDestruct.int32
        if o[10] == 1 and firstSd < 0: firstSd = t
        row.add o
      echoes.add row
      rec.frames.add frame
      if terminals[0] == 1: break
    let frames = rec.frames.len
    pw_destroy(a)
    check firstSd >= 0                                   # the match really contains a self-destruct
    # 2. A real .replay, reloaded and re-simulated by the engine (advance raises on a hash mismatch).
    let path = getTempDir() / "pw_seat_command_ex_sd.replay"
    replayRulesVersion = 49
    saveRecording(path, rec)
    recording = loadRecording(path)
    var sdInFile = 0
    for f in recording.frames:
      for c in f.commands:
        if c.selfDestruct: inc sdInFile
    check sdInFile > 0
    configureMap(recording.map); configureVision(recording.vision); configureGlory(recording.glory)
    world = newWorld(recording.seed, recording.endTick)
    while world.tick < recording.frames.len and world.winner == -1: advance()
    check world.tick == frames
    # 3. Command replay through a fresh library handle: _ex reproduces every frame and echo.
    proc replay(useEx: bool): tuple[mismatches, first, echoBad: int] =
      result.first = -1
      let b = newHandle(Seed, Ticks)
      var act: array[LegacySeats*ActionSizes.len, int32]
      var rew, term: array[LegacySeats, float32]
      for t, f in recording.frames:
        for slot in 0..<Seats:
          var c = ten(f.commands[slot])
          let rc = if useEx: pw_set_seat_command_ex(b, slot.cint, ibuf(c)) else: pw_set_seat_command(b, slot.cint, ibuf(c))
          doAssert rc == 0
        doAssert pw_step(b, ibuf(act), fbuf(rew), fbuf(term)) == 0
        if pw_state_hash(b) != f.hash:
          inc result.mismatches
          if result.first < 0: result.first = t
        if useEx:
          for slot in 0..<Seats:
            var o: array[11, int32]
            doAssert pw_seat_orders_ex(b, slot.cint, ibuf(o)) == 0
            let e = echoes[t][slot]
            # The raw command's echo: the nine fields, scripted = 0 (no script on b), self_destruct.
            for k in 0..<9:
              if o[k] != e[k]: inc result.echoBad
            if o[10] != e[10]: inc result.echoBad
      pw_destroy(b)
    let withEx = replay(true)
    check withEx.mismatches == 0 and withEx.echoBad == 0
    let without = replay(false)
    check without.mismatches > 0 and without.first >= firstSd   # from the first self-destruct that acts
    echo "self-destruct replay: ", frames, " frames, ", sdInFile, " self-destruct orders (first at tick ",
      firstSd, "); _ex: 0 hash mismatches; nine-field: diverges at tick ", without.first
    removeFile(path)

  test "self_destruct 0 is byte-identical to pw_set_seat_command":
    const Seed = 4902'i32
    const Ticks = 3000'i32
    let base = readFile(Base)
    let a = newHandle(Seed, Ticks)
    for slot in 0..<Seats:
      doAssert pw_set_seat_script(a, slot.cint, cast[ptr UncheckedArray[char]](unsafeAddr base[0]), base.len.int32) == 0
    let env = cast[ptr NativeEnv](a)
    var cmds: seq[seq[Command]]
    var actions: array[LegacySeats*ActionSizes.len, int32]
    var rewards, terminals: array[LegacySeats, float32]
    for t in 0..<Ticks:
      doAssert pw_step(a, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
      var row = env.scriptOrders[0..<Seats]
      for c in row.mitems: c.selfDestruct = false      # what pw_set_seat_command can express
      cmds.add row
      if terminals[0] == 1: break
    pw_destroy(a)
    let b = newHandle(Seed, Ticks)
    let c = newHandle(Seed, Ticks)
    var act: array[LegacySeats*ActionSizes.len, int32]
    var rew, term: array[LegacySeats, float32]
    var same = 0
    for row in cmds:
      for slot in 0..<Seats:
        var x = ten(row[slot])
        doAssert pw_set_seat_command(b, slot.cint, ibuf(x)) == 0
        doAssert pw_set_seat_command_ex(c, slot.cint, ibuf(x)) == 0
      doAssert pw_step(b, ibuf(act), fbuf(rew), fbuf(term)) == 0
      doAssert pw_step(c, ibuf(act), fbuf(rew), fbuf(term)) == 0
      var eq = pw_state_hash(b) == pw_state_hash(c)
      for slot in 0..<Seats:
        var ob, oc: array[10, int32]
        doAssert pw_seat_orders(b, slot.cint, ibuf(ob)) == 0 and pw_seat_orders(c, slot.cint, ibuf(oc)) == 0
        if ob != oc: eq = false
      if eq: inc same
    check same == cmds.len
    pw_destroy(b); pw_destroy(c)
