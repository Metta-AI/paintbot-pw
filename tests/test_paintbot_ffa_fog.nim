## FFA-kin fog of war (rules 48): no agent-facing surface shows a cog the seat cannot see. BASIC's
## kin, gene, seatScore and seatAlive read -1 for it (as playerX does); the ffa.v1 observation
## zeroes its row, for hosted and policy seats alike; shouts still carry within hearing range
## and reveal nothing else. Rules 47 and the teams game are unchanged; a rules-47 FFA recording
## made before rules 48 replays hash for hash.
import std/[unittest, os, importutils]
import polyworld/[cli, tapes]
import ../examples/paintbot/[sim, game, bots, kinship, neural_contract, native_env]
privateAccess(NativeEnv)

const Root = currentSourcePath().parentDir.parentDir

proc place(w: var World, slot: int, p: Point) =
  w.cogs[slot].hp = FfaMaxHp.int32
  w.cogs[slot].shield = 0
  w.cogs[slot].pos = p
  w.cogs[slot].goal = p
  w.equipment[slot].lives = 1

proc near(p: Point, dx = 0, dz = 0): Point = point(p.x.int+dx, p.z.int+dz)

proc arrange(w: var World) =
  ## Seat 0 faces +x. Seat 1 stands 300 ahead (in view); seat 2 stands 300 behind (out of view,
  ## within hearing range); seat 3 stands 3000 behind (out of view and out of hearing range).
  ## Every other seat is out of the match.
  for i in 0..<w.cogs.len:
    w.cogs[i].hp = 0
    w.equipment[i].lives = 0
  let spot = w.greatHearts[0].pos.near(0, 600)
  w.place(0, spot)
  w.place(1, spot.near(300))
  w.place(2, spot.near(-300))
  w.place(3, spot.near(-3000))
  w.cogs[0].aim = spot.near(1000)
  w.seatScore[1] = 70
  w.seatScore[2] = 90
  w.controlHearts[4].owner = 2

proc fogWorld(rules: int, k: Kinship): World =
  visionRulesVersion = rules
  gameMode = gmFfaKin
  kinshipOverride = some(k)
  result = newWorld(2026, 0)
  kinshipOverride = none(Kinship)
  result.arrange()

proc probe(w: World, slot: int, source: string, ticks = 1): Command =
  ## Runs `source` on every seat for `ticks` decisions of this unchanged world (speech carried
  ## between them) and returns seat `slot`'s last command.
  let path = getTempDir() / ("paintbot-ffa-fog-" & $getCurrentProcessId() & ".bas")
  writeFile(path, source)
  defer: removeFile(path)
  var players = loadBots(@[BotGroup(path: path, count: Seats)])
  heard = @[]
  var commands: seq[Command]
  for t in 0..<ticks:
    commands = players.decide(w)
    deliverSpeech(w)
  doAssert not players[slot].failed, players[slot].error
  commands[slot]

proc ask(w: World, a, b: string): (int32, int32) =
  let c = w.probe(0, "walkTo(" & a & ", " & b & ")\n")
  (c.goal.x, c.goal.z)

suite "FFA-kin fog of war (rules 48)":
  setup:
    kinshipOverride = none(Kinship)
  teardown:
    gameMode = gmTeams
    kinshipOverride = none(Kinship)
    visionRulesVersion = LiveRules
    heard = @[]

  test "rules 48 is live and gates the fog in FFA only":
    check LiveRules == 48 and FfaFogRules == 48
    visionRulesVersion = 48
    gameMode = gmFfaKin
    check ffaFog()
    gameMode = gmTeams
    check not ffaFog()
    visionRulesVersion = 47
    gameMode = gmFfaKin
    check not ffaFog()

  test "BASIC: a cog out of view reads unknown from every per-seat query":
    let k = kinshipFor(klCousins, 11)
    let w = fogWorld(48, k)
    check w.visible(0, 1) and not w.visible(0, 2) and not w.visible(0, 3)
    # In view: known.
    check w.ask("kin(1)", "seatScore(1)") == (k.rPercent(0, 1), 70'i32)
    check w.ask("seatAlive(1)", "gene(1, 0)") == (1'i32, int32(k.genes[1] and 1))
    check w.ask("playerX(1)", "playerHp(1)") == (w.cogs[1].pos.x, FfaMaxHp.int32)
    # Out of view (behind, and far behind): unknown, like playerX / playerHp.
    for hidden in [2, 3]:
      check w.ask("kin(" & $hidden & ")", "seatScore(" & $hidden & ")") == (-1'i32, -1'i32)
      check w.ask("seatAlive(" & $hidden & ")", "gene(" & $hidden & ", 0)") == (-1'i32, -1'i32)
      check w.ask("playerX(" & $hidden & ")", "playerHp(" & $hidden & ")") == (-1'i32, 0'i32)
      check w.ask("visible(" & $hidden & ")", "playerTeam(" & $hidden & ")") == (0'i32, -1'i32)
    # A cog out of the match is never in view.
    check w.ask("seatAlive(5)", "kin(5)") == (-1'i32, -1'i32)
    # The seat itself, the seat count and the hearts stay known.
    check w.ask("kin(0)", "seatScore(0)") == (100'i32, 0'i32)
    check w.ask("seatAlive(0)", "seatCount()") == (1'i32, Seats.int32)
    check w.ask("heartOwner(4)", "controlOwner(4)") == (2'i32, 2'i32)
    check w.ask("nearAgents(20000)", "nearAgentId(0)") == (1'i32, 1'i32)

  test "BASIC: rules 47 keeps kinship, genes, scores and who is playing public":
    let k = kinshipFor(klCousins, 11)
    let w = fogWorld(47, k)
    check not w.visible(0, 2)
    check w.ask("kin(2)", "seatScore(2)") == (k.rPercent(0, 2), 90'i32)
    check w.ask("seatAlive(2)", "gene(2, 0)") == (1'i32, int32(k.genes[2] and 1))
    check w.ask("seatAlive(5)", "kin(5)") == (0'i32, k.rPercent(0, 5))

  test "shouts carry within hearing range whatever the line of sight, and reveal nothing else":
    let k = kinshipFor(klCousins, 11)
    let w = fogWorld(48, k)
    # Every seat shouts on the first decision; on the second, seat 0 reports who it heard.
    let source = "shout(strNew(\"x\"))\n" &
      "if heardCount() >= 2 then\n  walkTo(heardSlot(0) * 100 + heardSlot(1), kin(heardSlot(1)))\n" &
      "else\n  walkTo(heardCount(), seatScore(2))\nend if\n"
    let c = w.probe(0, source, 2)
    # Seat 1 (in view) and seat 2 (behind, 300 away) are heard; seat 3 (3000 away) is not.
    check c.goal.x == 102
    # Hearing seat 2 does not make it known.
    check c.goal.z == -1'i32

  test "ffa.v1: an unseen cog's row is all zero at rules 48; rules 47 shows its public columns":
    let k = kinshipFor(klCousins, 11)
    var o = newSeq[float32](ObservationSizeFfaV1)
    proc row(j: int): int = FfaIdentityOffset + j*FfaIdentityRowSize
    let fogged = fogWorld(48, k)
    encodeObservation(fogged, 0, o, ocFfaV1)
    for hidden in [2, 3, 5]:
      for c in 0..<FfaIdentityRowSize: check o[row(hidden)+c] == 0
    # The seen cog and the seat's own row are unchanged.
    check o[row(1)+2] == 1 and o[row(1)+3] == 1 and o[row(1)+37] == float32(k.r(0, 1))
    check o[row(1)+38] == float32(70)/10000
    check o[row(0)+3] == 1 and o[row(0)+37] == 1
    # Hearts keep their owner's r.
    check o[FfaHeartOffset + 4*FfaHeartRowSize + 2] == float32(k.r(0, 2))
    let open = fogWorld(47, k)
    var p = newSeq[float32](ObservationSizeFfaV1)
    encodeObservation(open, 0, p, ocFfaV1)
    check p[row(2)+2] == 0 and p[row(2)+3] == 1 and p[row(2)+37] == float32(k.r(0, 2))
    check p[row(2)+38] == float32(90)/10000
    # Only the unseen rows differ between the rules.
    for i in 0..<ObservationSizeFfaV1:
      let unseenRow = i >= row(2) and i < row(LegacySeats)  # seats 2..15: none in view
      if not unseenRow: check o[i] == p[i]

  test "native: pw_observe and a policy seat's observation hold no genes or r of an unseen cog":
    let h = pw_create_observation(3, 0, 101)
    require h != nil
    check pw_set_rules(h, 48) == 0 and pw_set_game_mode(h, 1) == 0 and pw_set_kin_layout(h, 3) == 0
    check pw_reset(h, 2026, 240) == 0
    let env = cast[ptr NativeEnv](h)
    env.world.arrange()
    for s in 0..<LegacySeats: env.bodiesReady[s] = false
    # A policy seat on seat 0 reads its own observation's row for seat 2 through neuralObs.
    let manifest = """{"schema": "paintbot-neural-basic/1", "observation_contract": """" &
      ObservationContractFfaV1Hash & """", "action_contract": """" & ActionContractHash & """"}"""
    let r2 = FfaIdentityOffset + 2*FfaIdentityRowSize
    let script = "walkTo(neuralObs(" & $(r2+3) & ") + 5000, neuralObs(" & $(r2+37) & ") * 7 + neuralObs(" &
      $(r2+5) & ") + 5000)\n"
    check pw_set_seat_policy_script(h, 0, cast[ptr UncheckedArray[char]](unsafeAddr script[0]), script.len.int32,
      cast[ptr UncheckedArray[char]](unsafeAddr manifest[0]), manifest.len.int32) == 0
    var obs = newSeq[float32](16*ObservationSizeFfaV1)
    var resets = newSeq[float32](16)
    check pw_observe(h, cast[ptr UncheckedArray[cfloat]](addr obs[0]), cast[ptr UncheckedArray[cfloat]](addr resets[0])) == 0
    for c in 0..<FfaIdentityRowSize: check obs[r2+c] == 0
    var actions = newSeq[int32](16*ActionSizes.len)
    var logits = newSeq[float32](16*LogitSize)
    var rewards = newSeq[float32](16)
    var terminals = newSeq[float32](16)
    check pw_step_logits(h, cast[ptr UncheckedArray[int32]](addr actions[0]),
      cast[ptr UncheckedArray[cfloat]](addr logits[0]), cast[ptr UncheckedArray[cfloat]](addr rewards[0]),
      cast[ptr UncheckedArray[cfloat]](addr terminals[0])) == 0
    var orders = newSeq[int32](10)
    check pw_seat_orders(h, 0, cast[ptr UncheckedArray[int32]](addr orders[0])) == 0
    check orders[0] == 1 and orders[1] == 5000 and orders[2] == 5000
    # The privileged trainer reads stay whole.
    var kin = newSeq[float32](256)
    check pw_kin(h, cast[ptr UncheckedArray[cfloat]](addr kin[0])) == 0
    check kin[2] == float32(env.kinship.r(0, 2))
    pw_destroy(h)

  test "a rules-47 FFA recording made before rules 48 replays hash for hash":
    # Recorded on origin/main 0ff41d2 (rules 47): 16 ffa.bas seats, cousins, seed 2047, 300
    # ticks, gameVersion 1047. Never re-record it.
    let path = Root / "tests/data/paintbot_ffa_1047.replay"
    check loadReplayFileHeader(path).gameVersion == 1047
    gameMode = gmTeams
    let loaded = loadRecording(path)
    check gameMode == gmFfaKin
    check replayRulesVersion == 47 and visionRulesVersion == 47
    check not ffaFog()
    check loaded.frames.len == 300
    recording = loaded
    replayMode = true
    world = newWorld(recording.seed, recording.endTick)
    while world.tick < recording.frames.len and world.winner == -1: advance()
    replayMode = false
    check world.tick == 300
    check world.stateHash() == 466460896'u32
    replayRulesVersion = LiveRules
