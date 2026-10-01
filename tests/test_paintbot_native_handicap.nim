## Curriculum handicaps on the native training environment (pw_set_seat_max_hp, pw_set_seat_lives,
## pw_set_seat_damage_taken, pw_set_team_capture_ticks, pw_set_seat_respawn_ticks) and the fractional
## damage of pw_set_seat_damage_scale: every knob neutral leaves a match byte-identical; each knob has
## the effect it names; the carried fraction is deterministic and belongs to the match.
## Build with --mm:arc --threads:on -d:pwTraining.
import std/[unittest, os, importutils]
import ../examples/paintbot/[sim, neural_contract, native_env]

when not defined(pwTraining): {.error: "curriculum handicaps exist only under -d:pwTraining".}

const Root = currentSourcePath().parentDir.parentDir
const Base = Root / "coworld/paintbot/players/base.bas"
type Buffer = ptr UncheckedArray[cfloat]
template fbuf(a: untyped): Buffer = cast[Buffer](addr a[0])
template ibuf(a: untyped): ptr UncheckedArray[int32] = cast[ptr UncheckedArray[int32]](addr a[0])
privateAccess(NativeEnv)

proc envOf(h: pointer): ptr NativeEnv = cast[ptr NativeEnv](h)

proc scriptedWorld(seed, ticks: int32, source: string): pointer =
  result = pw_create(seed, ticks)
  doAssert result != nil
  for slot in 0..<Seats:
    doAssert pw_set_seat_script(result, slot.cint,
      cast[ptr UncheckedArray[char]](unsafeAddr source[0]), source.len.int32) == 0

proc play(handle: pointer, ticks: int): seq[uint32] =
  var actions: array[LegacySeats*ActionSizes.len, int32]
  var rewards, terminals: array[LegacySeats, float32]
  for tick in 0..<ticks:
    if terminals[0] == 1: break
    doAssert pw_step(handle, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
    result.add pw_state_hash(handle)

proc stepIdle(handle: pointer, ticks: int) =
  ## Every seat caller-driven with all heads 0 (stay, keep aim, no fire).
  var actions: array[LegacySeats*ActionSizes.len, int32]
  var rewards, terminals: array[LegacySeats, float32]
  for tick in 0..<ticks: doAssert pw_step(handle, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0

proc hitOnce(handle: pointer, victim, attacker, amount: int) =
  ## One damage event as the step deals it, with the handle's knobs in force.
  let env = envOf(handle)
  env.world.cogs[victim].shield = 0
  damageScale = addr env.damagePermille
  handicap = addr env.handicapKnobs
  try: env.world.damage(victim, attacker, amount)
  finally:
    damageScale = nil
    handicap = nil

suite "Native curriculum handicaps":
  configureRules(NativeRules)
  let baseSource = readFile(Base)

  test "every knob neutral (0, or 1000 for the damage scales) leaves a scripted world byte-identical":
    let reference = scriptedWorld(21, 1200, baseSource)
    let expected = play(reference, 1200)
    pw_destroy(reference)
    let knobbed = scriptedWorld(21, 1200, baseSource)
    # Set every knob away from neutral and back: the world must not remember it.
    for slot in 0..<Seats:
      check pw_set_seat_max_hp(knobbed, slot.cint, 5) == 0 and pw_set_seat_max_hp(knobbed, slot.cint, 0) == 0
      check pw_set_seat_lives(knobbed, slot.cint, 2) == 0 and pw_set_seat_lives(knobbed, slot.cint, 0) == 0
      check pw_set_seat_damage_taken(knobbed, slot.cint, 500) == 0 and pw_set_seat_damage_taken(knobbed, slot.cint, 1000) == 0
      check pw_set_seat_respawn_ticks(knobbed, slot.cint, 144) == 0 and pw_set_seat_respawn_ticks(knobbed, slot.cint, 0) == 0
      check pw_set_seat_damage_scale(knobbed, slot.cint, 1000) == 0
    for side in 0..1:
      check pw_set_team_capture_ticks(knobbed, side.cint, 144) == 0 and pw_set_team_capture_ticks(knobbed, side.cint, 0) == 0
    check pw_reset(knobbed, 21, 1200) == 0
    check play(knobbed, 1200) == expected
    pw_destroy(knobbed)

  test "max_hp: the seat spawns with it (next reset), takes that many 1-point hits, a medkit-free respawn restores it":
    let h = pw_create(5, 2400)
    require h != nil
    defer: pw_destroy(h)
    check pw_set_seat_max_hp(h, 0, 6) == 0
    check pw_set_seat_max_hp(h, 1, 1) == 0
    check envOf(h).world.cogs[0].hp == 3   # not until the next reset
    check pw_reset(h, 5, 2400) == 0
    let w = addr envOf(h).world
    check w[].cogs[0].hp == 6 and w[].cogs[1].hp == 1 and w[].cogs[2].hp == 3
    for i in 1..5: hitOnce(h, 0, 3, 1)
    check w[].cogs[0].hp == 1
    hitOnce(h, 0, 3, 1)
    check w[].cogs[0].hp == 0
    var waited = 0
    while w[].cogs[0].hp == 0 and waited < 400:
      stepIdle(h, 1); inc waited
    check w[].cogs[0].hp == 6   # respawned with its max

  test "lives: the seat starts with them (next reset) and is out after that many deaths":
    let h = pw_create(6, 2400)
    require h != nil
    defer: pw_destroy(h)
    check pw_set_seat_lives(h, 0, 2) == 0
    check pw_reset(h, 6, 2400) == 0
    let w = addr envOf(h).world
    check w[].equipment[0].lives == 2 and w[].equipment[2].lives == 4
    for death in 1..2:
      while w[].cogs[0].hp > 0: hitOnce(h, 0, 3, 1)
      check w[].equipment[0].lives == int32(2 - death)
      if death < 2:
        var waited = 0
        while w[].cogs[0].hp == 0 and waited < 400:
          stepIdle(h, 1); inc waited
        check w[].cogs[0].hp > 0
    stepIdle(h, 300)
    check w[].cogs[0].hp == 0   # out of lives: never respawns
    check pw_set_seat_lives(h, 0, 0) == 0
    check pw_reset(h, 6, 2400) == 0
    check envOf(h).world.equipment[0].lives == 4   # 0 restores the rules' lives

  test "respawn_ticks: a dead seat waits that long; 0 restores RespawnTicks":
    let h = pw_create(7, 2400)
    require h != nil
    defer: pw_destroy(h)
    check pw_set_seat_respawn_ticks(h, 0, 144) == 0
    let w = addr envOf(h).world
    while w[].cogs[0].hp > 0: hitOnce(h, 0, 3, 1)
    check w[].cogs[0].respawn == 144
    while w[].cogs[2].hp > 0: hitOnce(h, 2, 3, 1)
    check w[].cogs[2].respawn == RespawnTicks

  test "damage_taken 500: every other 1-point hit lands; with the attacker scale too, one in four":
    let h = pw_create(8, 2400)
    require h != nil
    defer: pw_destroy(h)
    let w = addr envOf(h).world
    check pw_set_seat_damage_taken(h, 4, 500) == 0
    w[].cogs[4].hp = 6
    var seen: seq[int32]
    for i in 1..6:
      hitOnce(h, 4, 3, 1); seen.add w[].cogs[4].hp
    check seen == @[6'i32, 5, 5, 4, 4, 3]
    # The attacker scale carries its fraction the same way (it used to floor every hit to 0).
    check pw_set_seat_damage_taken(h, 4, 1000) == 0
    check pw_set_seat_damage_scale(h, 3, 500) == 0
    w[].cogs[4].hp = 6
    seen = @[]
    for i in 1..4:
      hitOnce(h, 4, 3, 1); seen.add w[].cogs[4].hp
    check seen == @[6'i32, 5, 5, 4]
    check pw_set_seat_damage_taken(h, 4, 500) == 0
    check pw_reset(h, 8, 2400) == 0   # the carried fractions belong to the match
    w[].cogs[4].hp = 6
    seen = @[]
    for i in 1..8:
      hitOnce(h, 4, 3, 1); seen.add w[].cogs[4].hp
    check seen == @[6'i32, 6, 6, 5, 5, 5, 5, 4]
    # Deterministic: the same hits after the next reset give the same sequence.
    check pw_reset(h, 8, 2400) == 0
    w[].cogs[4].hp = 6
    var again: seq[int32]
    for i in 1..8:
      hitOnce(h, 4, 3, 1); again.add w[].cogs[4].hp
    check again == seen

  test "capture_ticks: a team holds an enemy heart alone that many ticks to take it":
    proc captureTime(knob: int32): int =
      let h = pw_create(9, 2400)
      doAssert h != nil
      defer: pw_destroy(h)
      doAssert pw_set_team_capture_ticks(h, 0, knob) == 0
      let w = addr envOf(h).world
      var target = -1
      for k, heart in w[].controlHearts:
        if heart.owner == 1: target = k; break
      doAssert target >= 0
      var far = target
      for k, heart in w[].controlHearts:
        if distance2(heart.pos, w[].controlHearts[target].pos) > distance2(w[].controlHearts[far].pos, w[].controlHearts[target].pos):
          far = k
      let at = w[].controlHearts[target].pos
      let away = w[].controlHearts[far].pos
      for i in 0..<Seats:
        let p = if i == 0: at else: away
        w[].cogs[i].pos = p; w[].cogs[i].goal = p
      result = 0
      while w[].controlHearts[target].owner != 0 and result < 600:
        stepIdle(h, 1); inc result
    let normal = captureTime(0)
    let slow = captureTime(144)
    let fast = captureTime(36)
    check normal in (HeartCaptureTicks - 2)..(HeartCaptureTicks + 2)
    check slow - normal == 144 - HeartCaptureTicks
    check normal - fast == HeartCaptureTicks - 36

  test "invalid arguments are refused":
    let h = pw_create(3, 600)
    require h != nil
    defer: pw_destroy(h)
    check pw_set_seat_max_hp(h, 0, 31) == -1 and pw_set_seat_max_hp(h, 0, -1) == -1 and pw_set_seat_max_hp(h, 16, 3) == -1
    check pw_set_seat_lives(h, 0, 9) == -1 and pw_set_seat_lives(nil, 0, 2) == -1
    check pw_set_seat_damage_taken(h, 0, -1) == -1 and pw_set_seat_damage_taken(h, 0, 10001) == -1
    check pw_set_team_capture_ticks(h, 2, 72) == -1 and pw_set_team_capture_ticks(h, 0, 35) == -1
    check pw_set_team_capture_ticks(h, 0, 145) == -1 and pw_set_team_capture_ticks(h, 0, 0) == 0
    check pw_set_seat_respawn_ticks(h, 0, -1) == -1 and pw_set_seat_respawn_ticks(h, 0, 1441) == -1
