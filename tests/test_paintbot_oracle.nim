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
    # 1 and 2 were dropped as the oldest; 6 is stored, and an answered request that carried
    # nothing usable settles as failed rather than as 0, which oraclePoll reports as pending.
    check shouts[2] == @["-1", "-1", "-1"]

  test "a text-heavy decision fits the string pool":
    var w = arena()
    let players = bots("i = 0\nwhile i < 600\n  s = strFromInt(i)\n  i = i + 1\nwend\nshout(strFromInt(i))\n")
    discard players.decide(w)
    check not players[2].failed
    check shouts[2] == @["600"]
    check peakStrings[2] > 600


  test "state keys are paths: rows of fields become arrays of objects":
    # Building one prose sentence per candidate costs a string operation per fragment. A path
    # key writes the same facts as fields at int prices, and Jev sees structure, not prose.
    var w = arena()
    let players = bots("""
oracleState(strNew("candidates[0].heart"), 7)
oracleStateText(strNew("candidates[0].owner"), strNew("enemy"))
oracleState(strNew("candidates[1].heart"), 4)
oracleState(strNew("me.hp_of_3"), selfHp)
oracleStateText(strNew("me.phase"), strNew("midgame"))
oracleState(strNew("plain_key"), 1)
oracleState(strNew("not[a path"), 2)
oracleQuestion(strNew("q"), 0, strNew("?"))
oracleCriterion(strNew("q"), strNew("true"), strNew("yes"))
oracleCriterion(strNew("q"), strNew("false"), strNew("no"))
req = oracleAsk()
""")
    discard players.decide(w)
    let state = parseJson(drainOracleAsks()[0].body)["state"]
    check state["candidates"].kind == JArray
    check state["candidates"].len == 2
    check state["candidates"][0]["heart"].getInt == 7
    check state["candidates"][0]["owner"].getStr == "enemy"
    check state["candidates"][1]["heart"].getInt == 4
    check state["me"]["hp_of_3"].getInt == 3
    check state["me"]["phase"].getStr == "midgame"
    check state["plain_key"].getInt == 1
    # A key that is not a well-formed path stays a flat field instead of being dropped.
    check state["not[a path"].getInt == 2

  test "a criterion carries extra fields as an object, repeats as an array":
    var w = arena()
    let players = bots("""
oracleQuestion(strNew("pick"), 2, strNew("Which?"))
oracleCriterion(strNew("pick"), strNew("keep"), strNew("keep the current objective"))
oracleCriterionField(strNew("pick"), strNew("keep"), strNew("not_for"), strNew("a stale objective"))
oracleCriterionField(strNew("pick"), strNew("keep"), strNew("examples"), strNew("still closing on it"))
oracleCriterionField(strNew("pick"), strNew("keep"), strNew("examples"), strNew("nothing nearer is free"))
oracleCriterion(strNew("pick"), strNew("C0"), strNew("take the near heart"))
shout(strFromInt(oracleCriterionField(strNew("pick"), strNew("absent"), strNew("x"), strNew("y"))))
req = oracleAsk()
""")
    discard players.decide(w)
    let criteria = parseJson(drainOracleAsks()[0].body)["questions"]["pick"]["criteria"]
    check criteria["keep"]["what"].getStr == "keep the current objective"
    check criteria["keep"]["not_for"].getStr == "a stale objective"
    check criteria["keep"]["examples"].kind == JArray
    check criteria["keep"]["examples"].len == 2
    check criteria["keep"]["examples"][1].getStr == "nothing nearer is free"
    # A criterion with no extra fields stays a plain string, and an unknown label is refused.
    check criteria["C0"].getStr == "take the near heart"
    check shouts[2] == @["0"]

  test "oracleReady says when an ask would be accepted, so no draft is wasted":
    var w = arena()
    const Probe = "shout(strFromInt(oracleReady()))\n"
    discard bots(Probe).decide(w)
    check shouts[2] == @["0"]
    let asker = bots("oracleQuestion(strNew(\"q\"), 0, strNew(\"?\"))\nr = oracleAsk()\nshout(strFromInt(oracleReady()))\n")
    discard asker.decide(w)
    # One request in flight: -1 until it settles, then the ticks still to wait.
    check shouts[2] == @["-1"]
    discard drainOracleAsks()
    deliverOracleReply(OracleReply(slot: 2, id: 1, status: -1))
    w.step(default(array[Seats,Command]))
    discard bots(Probe).decide(w)
    check shouts[2] == @["23"]
    while w.tick < 24: w.step(default(array[Seats,Command]))
    discard bots(Probe).decide(w)
    check shouts[2] == @["0"]
    oracleEnabled = false
    discard bots(Probe).decide(w)
    check shouts[2] == @["-1"]

  test "the journal reproduces each request exactly and records its answer":
    # Hosted episodes return only the seats' logs, so the journal is the only way to replay a
    # decision offline. It must rebuild the body byte for byte, or re-asking Jev with a variant
    # prompt would compare against a request that was never sent.
    var lines: seq[tuple[slot: int, line: string]]
    oracleJournal = proc(slot: int, line: string) = lines.add (slot, line)
    defer: oracleJournal = nil
    var w = arena()
    let players = bots(Advised)
    discard players.decide(w)
    let asks = drainOracleAsks()
    check asks.len == 1
    var questions: Table[string, string]
    var askLine = ""
    for (slot, line) in lines:
      check slot == 2
      check line.endsWith("\n")
      check line.count('\n') == 1
      if line.startsWith("oracle-q "):
        let parts = line.strip.split(' ', 2)
        questions[parts[1][2..^1]] = parts[2]
      elif line.startsWith("oracle-ask "): askLine = line.strip
    check questions.len == 1
    let parts = askLine.split(' ', 4)
    check parts[1] == "id=1"
    let rebuilt = "{\"state\":" & parts[4] & ",\"questions\":" & questions[parts[3][2..^1]] & "}"
    check rebuilt == asks[0].body

    # A second ask with the same question set names it by hash and does not repeat the text.
    lines = @[]
    deliverOracleReply(OracleReply(slot: 2, id: 1, status: -1))
    while w.tick < 24: w.step(default(array[Seats,Command]))
    discard bots(Advised).decide(w)
    discard drainOracleAsks()
    var sawQuestions = false
    for (slot, line) in lines:
      if line.startsWith("oracle-q "): sawQuestions = true
    check not sawQuestions

    # The answer line carries value, confidence and the distribution, scaled as a script reads them.
    lines = @[]
    var answers: Table[string, OracleAnswer]
    answers["formation"] = OracleAnswer(value: 1, confidence: 800,
        probabilities: {"spread": 250'i32, "pairs": 750'i32}.toTable)
    deliverOracleReply(OracleReply(slot: 2, id: 2, status: 1, answers: answers))
    check lines.len == 1
    check lines[0].line.startsWith("oracle-ans id=2 ")
    check "status=1" in lines[0].line
    let body = parseJson(lines[0].line.strip.split(' ', 4)[4])
    check body["formation"]["v"].getInt == 1
    check body["formation"]["c"].getInt == 800
    check body["formation"]["p"]["pairs"].getInt == 750

  test "no journal is written when nothing is listening":
    check oracleJournal == nil
    var w = arena()
    discard bots(Advised).decide(w)
    check drainOracleAsks().len == 1
