## FFA-kin BASIC host functions: kinship, genes, raw scores, who is still in the match, heart
## owners and great hearts; selfTeam and playerTeam read the seat. In the teams game the new
## functions read "no FFA" and the old data is unchanged.
import std/[unittest, os, strutils]
import polyworld/[cli, basic]
import ../examples/paintbot/[sim, bots, kinship]

const Root = currentSourcePath().parentDir.parentDir
const Base = Root / "coworld/paintbot/players/base.bas"

proc ask(w: World, slot: int, a, b: string): (int32, int32) =
  ## Runs `walkTo(a, b)` for every seat on this world and returns seat `slot`'s goal.
  let path = getTempDir() / "paintbot-ffa-basic-probe.bas"
  writeFile(path, "walkTo(" & a & ", " & b & ")\n")
  defer: removeFile(path)
  var players = loadBots(@[BotGroup(path: path, count: Seats)])
  let commands = players.decide(w)
  doAssert not players[slot].failed, players[slot].error
  (commands[slot].goal.x, commands[slot].goal.z)

proc ffaWorld(seed = 2026'i32): World =
  gameMode = gmFfaKin
  newWorld(seed)

suite "FFA-kin BASIC host":
  setup:
    visionRulesVersion = 40
    kinshipOverride = none(Kinship)
  teardown:
    gameMode = gmTeams
    kinshipOverride = none(Kinship)

  test "each function reads the hand-set FFA state":
    let k = kinshipFor(klCousins, 11)
    kinshipOverride = some(k)
    var w = ffaWorld()
    check activeKinship == k
    # Find a sibling, a cousin and a stranger of seat 0 in this layout.
    var sibling, cousin, stranger = -1
    for j in 1..<Seats:
      case k.ibd[0][j]
      of 16: sibling = j
      of 8: cousin = j
      of 0: stranger = j
      else: discard
    check sibling >= 0 and cousin >= 0 and stranger >= 0
    check w.ask(0, "gameMode()", "kin(0)") == (1'i32, 100'i32)
    check w.ask(0, "kin(" & $sibling & ")", "kin(" & $cousin & ")") == (50'i32, 25'i32)
    check w.ask(0, "kin(" & $stranger & ")", "kin(16)") == (0'i32, -1'i32)
    check w.ask(0, "kin(-1)", "kin(" & $sibling & ")") == (-1'i32, 50'i32)
    # Kinship is from the asker's point of view.
    check w.ask(sibling, "kin(0)", "kin(" & $sibling & ")") == (50'i32, 100'i32)
    for locus in [0, 5, 31]:
      let bit = int32((k.genes[3] shr locus.uint32) and 1)
      check w.ask(0, "gene(3, " & $locus & ")", "gene(3, 32)") == (bit, -1'i32)
    check w.ask(0, "gene(16, 0)", "gene(3, -1)") == (-1'i32, -1'i32)
    w.seatScore[5] = 123
    w.seatScore[6] = 7
    check w.ask(0, "seatScore(5)", "seatScore(6)") == (123'i32, 7'i32)
    check w.ask(0, "seatScore(16)", "seatScore(0)") == (-1'i32, 0'i32)
    # Seat 9 is out of the match; its genes are hidden, its kinship is not.
    w.cogs[9].hp = 0
    w.equipment[9].lives = 0
    check w.ask(0, "seatAlive(9)", "seatAlive(1)") == (0'i32, 1'i32)
    check w.ask(0, "seatAlive(16)", "gene(9, 0)") == (-1'i32, -1'i32)
    check w.ask(0, "kin(9)", "0") == (activeKinship.rPercent(0, 9), 0'i32)
    w.controlHearts[2].owner = 7
    check w.ask(0, "heartOwner(2)", "controlOwner(2)") == (7'i32, 7'i32)
    check w.ask(0, "heartOwner(3)", "heartOwner(" & $w.controlHearts.len & ")") == (-1'i32, -1'i32)
    w.heartCaptures[4] = HeartCapture(team: 12, ticks: 30)
    check w.ask(0, "controlCaptureTeam(4)", "controlCaptureTicks(4)") == (12'i32, 30'i32)
    check w.ask(0, "greatHeartCount()", "greatHeartX(2)") == (2'i32, -1'i32)
    for i in 0..1:
      check w.ask(0, "greatHeartX(" & $i & ")", "greatHeartY(" & $i & ")") ==
        (w.greatHearts[i].pos.x, w.greatHearts[i].pos.z)
    w.greatHearts[1].present = 3
    w.greatHearts[1].progress = 40
    w.greatHearts[1].dormantUntil = w.tick + 100
    check w.ask(0, "greatHeartPresent(1)", "greatHeartProgress(1)") == (3'i32, 40'i32)
    check w.ask(0, "greatHeartDormant(1)", "greatHeartDormant(0)") == (100'i32, 0'i32)
    check w.ask(0, "greatHeartPresent(-1)", "greatHeartDormant(2)") == (-1'i32, -1'i32)

  test "selfTeam, playerTeam and home read the seat in FFA":
    var w = ffaWorld()
    for slot in [0, 1, 6, 15]:
      check w.ask(slot, "selfTeam", "selfId") == (slot.int32, slot.int32)
      check w.ask(slot, "homeX", "homeY") == (w.spawnAnchor[slot].x, w.spawnAnchor[slot].z)
      check w.ask(slot, "heartX", "ownHeartStolen") == (w.spawnAnchor[slot].x, 0'i32)
    # Put seat 6 right in front of seat 0 on open ground.
    w.cogs[6].pos = point(w.cogs[0].pos.x.int + 150, w.cogs[0].pos.z.int)
    w.cogs[0].aim = w.cogs[6].pos
    check w.visible(0, 6)
    check w.ask(0, "visible(6)", "playerTeam(6)") == (1'i32, 6'i32)

  test "the teams game keeps exactly the old host names and team data":
    gameMode = gmTeams
    var w = newWorld(2026)
    # Submitted teams scripts may use any of the FFA names as plain variables.
    let names = ["kin", "gene", "heartOwner", "gameMode", "greatHeartCount", "greatHeartX",
      "greatHeartY", "greatHeartPresent", "greatHeartProgress", "greatHeartDormant",
      "seatScore", "seatAlive"]
    let path = getTempDir() / "paintbot-ffa-basic-names.bas"
    defer: removeFile(path)
    var source = ""
    for i, name in names: source.add name & " = " & $(i + 1) & "\n"
    source.add "walkTo(kin + gene * 100, seatScore + greatHeartX * 100)\n"
    writeFile(path, source)
    var players = loadBots(@[BotGroup(path: path, count: Seats)])
    let commands = players.decide(w)
    for slot in 0..<Seats:
      check not players[slot].failed
    check commands[0].goal == point(1 + 2*100, 11 + 6*100)
    # The same program is refused in FFA, where those names are host functions.
    gameMode = gmFfaKin
    expect BasicError: discard loadBots(@[BotGroup(path: path, count: Seats)])
    gameMode = gmTeams
    check w.ask(3, "selfTeam", "selfId") == (1'i32, 3'i32)
    check w.ask(2, "homeX", "homeY") == (home(0).x, home(0).z)
    check w.ask(3, "heartX", "heartY") == (w.hearts[0].pos.x, w.hearts[0].pos.z)

  test "sixteen base.bas seats play a whole FFA match without a failure":
    var w = ffaWorld(7)
    var players = loadBots(@[BotGroup(path: Base, count: Seats)])
    while w.winner == -1:
      let commands = players.decide(w)
      deliverSpeech(w)
      w.step(commands)
    check w.winner == -3
    check w.tick <= FfaMatchTicks
    for slot in 0..<Seats:
      check not players[slot].failed
      if players[slot].failed: echo "seat ", slot, ": ", players[slot].error
    echo "base.bas FFA: ", w.tick, " ticks, raw scores ", w.seatScore
