## The FFA-kin baseline players/ffa.bas: sixteen copies finish a match with points on the board,
## and they hit relatives (r >= 1/2) less, per pair, than strangers (r = 0). Hits are counted
## through sim's observeHit hook, which the engine calls on every damage event; nothing here
## changes the rules.
import std/[unittest, os, strformat]
import polyworld/cli
import ../examples/paintbot/[sim, bots, kinship]

const Root = currentSourcePath().parentDir.parentDir
const Ffa = Root / "coworld/paintbot/players/ffa.bas"

type MatchStats = object
  ticks, rawTotal: int
  kinHits, kinPairs, strangerHits, strangerPairs: int
  maxInstructions: int64

proc play(seed: int32): MatchStats =
  gameMode = gmFfaKin
  var w = newWorld(seed)
  var hits: array[Seats, array[Seats, int]]
  observeHit = proc(tick: int32, victim, attacker: int, pos: Point) =
    if attacker in 0..<Seats and attacker != victim: inc hits[attacker][victim]
  defer: observeHit = nil
  for slot in 0..<Seats: peakInstructions[slot] = 0
  var players = loadBots(@[BotGroup(path: Ffa, count: Seats)])
  while w.winner == -1:
    let commands = players.decide(w)
    deliverSpeech(w)
    w.step(commands)
  for slot in 0..<Seats:
    doAssert not players[slot].failed, "seat " & $slot & ": " & players[slot].error
    result.maxInstructions = max(result.maxInstructions, peakInstructions[slot])
  result.ticks = w.tick
  for i in 0..<Seats:
    result.rawTotal += w.seatScore[i]
    for j in 0..<Seats:
      if i == j: continue
      if activeKinship.ibd[i][j] >= 16:
        inc result.kinPairs
        result.kinHits += hits[i][j]
      elif activeKinship.ibd[i][j] == 0:
        inc result.strangerPairs
        result.strangerHits += hits[i][j]
  echo &"seed {seed}: layout {activeKinship.layout}, {w.tick} ticks, raw total {result.rawTotal}, " &
    &"kin hits {result.kinHits}/{result.kinPairs} pairs, stranger hits {result.strangerHits}/" &
    &"{result.strangerPairs} pairs, peak instructions {result.maxInstructions}"
  echo "  raw scores ", w.seatScore, " great shares ", w.greatShare

suite "FFA-kin baseline ffa.bas":
  setup:
    visionRulesVersion = 40
    kinshipOverride = none(Kinship)
  teardown:
    gameMode = gmTeams
    kinshipOverride = none(Kinship)

  test "sixteen ffa.bas seats score and hurt relatives less than strangers":
    # Layouts with both relatives and strangers: fours, pairs, trios and a loner.
    var kinRate, strangerRate = 0.0
    var seeds = 0
    for (layout, seed) in [(klFours, 101'i32), (klPairs, 202'i32), (klTriosLoner, 303'i32)]:
      kinshipOverride = some(kinshipFor(layout, seed))
      let stats = play(seed)
      check stats.rawTotal > 0
      check stats.ticks > 0
      check stats.maxInstructions < 50000
      kinRate += stats.kinHits / stats.kinPairs
      strangerRate += stats.strangerHits / stats.strangerPairs
      inc seeds
    kinRate /= seeds.float
    strangerRate /= seeds.float
    echo &"mean hits per kin pair {kinRate:.3f}, per stranger pair {strangerRate:.3f}"
    check kinRate < strangerRate

  test "a seed-drawn match finishes with points on the board":
    let stats = play(2026)
    check stats.rawTotal > 0
