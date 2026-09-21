import std/[unittest, os, json, tables, strutils]
import polyworld/[cli, basic]
import ../examples/paintbot/[sim, bots, game]

proc arena(): World =
  result = newWorld(2026)
  for i in 0..<Seats:
    result.cogs[i].hp = 0
    result.cogs[i].respawn = 1000
  result.cogs[2].hp = 3
  result.cogs[2].pos = point(3200,2000)
  result.cogs[2].goal = result.cogs[2].pos

# Asks once, then walks to (formation choice, P(pairs)) when the answer lands; shouts the poll status.
const Advised = """
if req = 0 then
  oracleState(strNew("lives"), livesLeft)
  oracleStateText(strNew("phase"), strNew("opening"))
  oracleNote(strNew("groups win fights"))
  oracleQuestion(strNew("formation"), 2, strNew("How should we group up?"))
  oracleCriterion(strNew("formation"), strNew("spread"), strNew("alone"))
  oracleCriterion(strNew("formation"), strNew("pairs"), strNew("in twos"))
  oracleQuestion(strNew("press"), 0, strNew("Finish them?"))
  oracleCriterion(strNew("press"), strNew("true"), strNew("yes"))
  oracleCriterion(strNew("press"), strNew("false"), strNew("no"))
  oracleQuestion(strNew("caution"), 1, strNew("How cautious?"))
  oracleCriterion(strNew("caution"), strNew(""), strNew("bold"))
  oracleCriterion(strNew("caution"), strNew(""), strNew("careful"))
  req = oracleAsk()
  again = oracleAsk()
else
  status = oraclePoll(req)
  shout(strFromInt(status))
  if status > 0 then
    walkTo(oracleAnswer(req, strNew("formation")), oracleProbability(req, strNew("formation"), strNew("pairs")))
    lookAt(oracleAnswer(req, strNew("press")), oracleConfidence(req, strNew("caution")))
    print oracleAnswer(req, strNew("missing"))
  end if
end if
"""

proc bots(source: string): array[Seats,Bot] =
  let path = getTempDir()/"paintbot-oracle-test.bas"
  writeFile(path, source)
  defer: removeFile(path)
  loadBots(@[BotGroup(path:path,count:Seats)])

suite "BASIC advisor oracle":
  setup:
    resetOracle()
    oracleEnabled = true
    oracleInterval = 24

  test "a script drafts one typed request and the engine ships it as JSON":
    var w = arena()
    let players = bots(Advised)
    discard players.decide(w)
    let asks = drainOracleAsks()
    check asks.len == 1
    check asks[0].slot == 2 and asks[0].id == 1
    check asks[0].body.len <= MaxBodyBytes
    let body = parseJson(asks[0].body)
    check body["state"]["lives"].getInt == w.equipment[2].lives.int
    check body["state"]["phase"].getStr == "opening"
    check body["state"]["notes"][0].getStr == "groups win fights"
    check body["questions"]["formation"]["type"].getStr == "choice"
    check body["questions"]["formation"]["criteria"]["pairs"].getStr == "in twos"
    check body["questions"]["press"]["type"].getStr == "noul"
    check body["questions"]["caution"]["type"].getStr == "score"
    check body["questions"]["caution"]["criteria"].len == 2
    check body["questions"]["caution"]["criteria"][1].getStr == "careful"
    check drainOracleAsks().len == 0

  test "answers land on a later tick, are scaled by 1000, and are read by key":
    var w = arena()
    let players = bots(Advised)
    discard players.decide(w)
    discard drainOracleAsks()
    w.step(default(array[Seats,Command]))
    var commands = players.decide(w)
    check not commands[2].walk
    check shouts[2] == @["0"]
    var answers: Table[string, OracleAnswer]
    answers["formation"] = OracleAnswer(value: 1, confidence: 800,
        probabilities: {"spread": 250'i32, "pairs": 750'i32}.toTable)
    answers["press"] = OracleAnswer(value: 900, confidence: -1)
    answers["caution"] = OracleAnswer(value: 1500, confidence: 400)
    deliverOracleReply(OracleReply(slot: 2, id: 1, status: 3, answers: answers))
    w.step(default(array[Seats,Command]))
    commands = players.decide(w)
    check shouts[2] == @["3"]
    check commands[2].walk
    check commands[2].goal == point(1, 750)
    check commands[2].aim == point(900, 400)

  test "a failed request reports -1 and the seat may ask again after the interval":
    var w = arena()
    let players = bots(Advised)
    discard players.decide(w)
    discard drainOracleAsks()
    deliverOracleReply(OracleReply(slot: 2, id: 1, status: -1))
    w.step(default(array[Seats,Command]))
    discard players.decide(w)
    check shouts[2] == @["-1"]
    # Ask again: still inside the interval, refused; at the interval, accepted with a new id.
    let retry = bots("if worldTick > 0 then\n  oracleQuestion(strNew(\"q\"), 0, strNew(\"?\"))\n  r = oracleAsk()\n  shout(strFromInt(r))\nend if\n")
    discard retry.decide(w)
    check shouts[2] == @["0"]
    while w.tick < 24: w.step(default(array[Seats,Command]))
    discard retry.decide(w)
    check shouts[2] == @["2"]
    check drainOracleAsks()[0].id == 2

  test "without an oracle every ask is refused and nothing is shipped":
    oracleEnabled = false
    var w = arena()
    let players = bots("oracleQuestion(strNew(\"q\"), 0, strNew(\"?\"))\nshout(strFromInt(oracleAsk()))\nshout(strFromInt(oracleAvailable()))\n")
    discard players.decide(w)
    check shouts[2] == @["0", "0"]
    check drainOracleAsks().len == 0

  test "oversized drafts and bad keys are refused, at most four answers are kept":
    var w = arena()
    var src = "oracleQuestion(strNew(\"q\"), 0, strNew(\"?\"))\n"
    for i in 0..<40:
      src.add "oracleStateText(strNew(\"k" & $i & "\"), strNew(\"" & repeat('x', 1000) & "\"))\n"
    src.add "shout(strFromInt(oracleAsk()))\nshout(strFromInt(oracleQuestion(strNew(\"\"), 0, strNew(\"?\"))))\nshout(strFromInt(oracleQuestion(strNew(\"k\"), 3, strNew(\"?\"))))\n"
    discard bots(src).decide(w)
    check shouts[2] == @["0", "0", "0"]
    for id in 1..6:
      deliverOracleReply(OracleReply(slot: 2, id: id, status: 0))
    let poll = bots("shout(strFromInt(oraclePoll(1)))\nshout(strFromInt(oraclePoll(2)))\nshout(strFromInt(oraclePoll(6)))\n")
    discard poll.decide(w)
    check shouts[2] == @["-1", "-1", "0"]

  test "a text-heavy decision fits the 1,024-handle string pool":
    var w = arena()
    let players = bots("i = 0\nwhile i < 600\n  s = strFromInt(i)\n  i = i + 1\nwend\nshout(strFromInt(i))\n")
    discard players.decide(w)
    check not players[2].failed
    check shouts[2] == @["600"]
    check peakStrings[2] > 600

