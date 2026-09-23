## `players/jev.bas` is the BASIC baseline with the Jev advisor layer spliced in by
## `coworld/paintbot/tools/make_jev_baseline.py`. Where no oracle is configured (certification
## pods, this suite) every ask is refused, and the file must then play exactly like `base.bas`:
## the same state hash tick for tick, no seat disabled, and a per-decision cost that stays well
## inside the BASIC budget even though it drafts oracle requests.
import std/[unittest, os, strutils, tables, json]
import polyworld/[cli, basic]
import ../examples/paintbot/[sim, bots, oracle]

const Ticks = 720   # thirty seconds: the layer's first asks, shouts and heart flips all fall inside
const Root = currentSourcePath().parentDir.parentDir
const Base = Root / "coworld/paintbot/players/base.bas"
const Jev = Root / "coworld/paintbot/players/jev.bas"

proc play(path: string, seed: int32, advised = false): (seq[uint32], array[Seats, Bot]) =
  resetOracle()
  oracleEnabled = advised
  peakInstructions = default(array[Seats, int64])
  peakWork = default(array[Seats, int64])
  peakStrings = default(array[Seats, int64])
  var w = newWorld(seed)
  let players = loadBots(@[BotGroup(path: path, count: Seats)])
  var hashes: seq[uint32]
  while w.tick < Ticks and w.winner == -1:
    let commands = players.decide(w)
    deliverSpeech(w)
    w.step(commands)
    hashes.add w.stateHash()
  (hashes, players)

suite "Jev-advised BASIC baseline":
  test "the shipped copies are the same file":
    check readFile(Jev) == readFile(Root / "examples/paintbot/players/jev.bas")

  test "without an oracle jev.bas plays exactly like base.bas":
    for seed in [4'i32, 5, 8]:
      let (baseHashes, _) = play(Base, seed)
      let (jevHashes, players) = play(Jev, seed)
      check baseHashes.len == Ticks
      check jevHashes == baseHashes
      for slot in 0..<Seats:
        check not players[slot].failed
      check drainOracleAsks().len == 0

  test "drafting the oracle request stays inside the BASIC budget":
    # With the oracle on and no replies the askers draft and ship requests every ask interval.
    # Limits are 50,000 instructions, 125,000 work units and 1,024 string handles per decision;
    # measured peaks are about 10,100 / 22,200 / 91, and about 10,900 / 25,500 / 101 with every
    # switch on. Guard three quarters of each limit.
    let (_, players) = play(Jev, 4, advised = true)
    check drainOracleAsks().len > 0
    for slot in 0..<Seats:
      check not players[slot].failed
      check peakInstructions[slot] < 37_500
      check peakWork[slot] < 93_750
      check peakStrings[slot] < 768

  test "Jev's pick is relayed as a squad callout that squadmates decode":
    # An answered ask makes the asker shout "<Squad>, push <Heart>." (or hold / carry on) every
    # two seconds; the heart's name starts with A + its index. Squadmates within earshot adopt
    # it and log "relay ... obj=<heart> kind=<kind>". Nothing shouts the old "jev 0 5 0" form.
    # With useEcho = 0 the adopters stay quiet: a squad's directive has one voice, so the wire
    # carries one callout per answer instead of four, and an adoption cannot refresh another
    # adopter's hold or keep a dead asker's seat from being taken over.
    const Names = ["Anvil", "Bridge", "Chapel", "Dock", "Elm", "Forge", "Gate", "Hollow", "Inn",
        "Jetty", "Kiln", "Lookout", "Mill", "Nook", "Orchard", "Pier"]
    resetOracle()
    oracleEnabled = true
    var w = newWorld(4)
    var players = loadBots(@[BotGroup(path: Jev, count: Seats)])
    var lines: array[Seats, string]
    var relays: seq[tuple[tick, slot, heart, kind: int]]
    var firstAnswer: array[Seats, int]
    for slot in 0..<Seats: firstAnswer[slot] = -1
    proc printer(s: int): PrintProc =
      # A proc per slot: a closure made in a loop body would share one captured `slot`.
      result = proc(e: PrintEvent) =
        case e.kind
        of TextPrint: lines[s].add e.text
        of ValuePrint: lines[s].add $e.value
        of NewlinePrint:
          if lines[s].startsWith("ans ") and firstAnswer[s] < 0:
            firstAnswer[s] = parseInt(lines[s].split(' ')[1].split('=')[1])
          if lines[s].startsWith("relay "):
            var f = initTable[string, int]()
            for part in lines[s].split(' '):
              if '=' in part: f[part.split('=')[0]] = parseInt(part.split('=')[1])
            relays.add (f["t"], s, f["obj"], f["kind"])
          lines[s] = ""
    for slot in 0..<Seats:
      players[slot].output = printer(slot)
    var callouts: seq[tuple[tick, slot: int, text: string]]
    while w.tick < Ticks and w.winner == -1:
      let commands = players.decide(w)
      for ask in drainOracleAsks():
        var answers = initTable[string, OracleAnswer]()
        answers["objective"] = OracleAnswer(value: 0, confidence: 1000,
            probabilities: {"C0": 900'i32, "current": 100'i32}.toTable)
        deliverOracleReply(OracleReply(slot: ask.slot, id: ask.id, status: 1, answers: answers))
      for slot in 0..<Seats:
        for m in shouts[slot]:
          check not m.startsWith("jev ")
          if m.startsWith("Alpha, ") or m.startsWith("Bravo, "):
            callouts.add (w.tick.int, slot, m)
      deliverSpeech(w)
      w.step(commands)
    for slot in 0..<Seats:
      check not players[slot].failed
    check callouts.len > 0
    var pushes = 0
    for c in callouts:
      let words = c.text.split(' ')
      check words.len == 3
      check words[1] in ["push", "hold", "carry"]
      if words[1] == "carry":
        check words[2] == "on."
      else:
        check words[2].endsWith(".")
        check words[2][0..^2] in Names
        inc pushes
    check pushes > 0
    check relays.len > 0
    # Every adoption names the heart a same-team callout announced, decoded from its first letter.
    for r in relays:
      var announced = false
      for c in callouts:
        if c.tick < r.tick and c.slot mod 2 == r.slot mod 2 and c.slot != r.slot:
          let words = c.text.split(' ')
          if words[1] != "carry" and int(words[2][0]) - int('A') == r.heart and
              (words[1] == "hold") == (r.kind == 1):
            announced = true
      check announced
    # One voice: a cog may only speak for its squad after one of its OWN asks was answered, so a
    # cog that has merely adopted someone else's callout stays silent. Checked per callout rather
    # than by finding one permanently silent adopter, because with `useRetreat`/`useDial` on every cog asks
    # for itself when it is hurt and so eventually earns the right to speak.
    for c in callouts:
      check firstAnswer[c.slot] >= 0
      check c.tick >= firstAnswer[c.slot]

  test "the drafted request is structured state, not sentences":
    # Facts go out as fields under path keys and the criteria point at them, so Jev reads
    # structure rather than prose and the options are not restated in the state.
    resetOracle()
    oracleEnabled = true
    var w = newWorld(4)
    let players = loadBots(@[BotGroup(path: Jev, count: Seats)])
    discard players.decide(w)
    let asks = drainOracleAsks()
    check asks.len > 0
    let body = parseJson(asks[0].body)
    let state = body["state"]
    let questions = body["questions"]

    check state["candidates"].kind == JArray
    check state["candidates"].len > 0
    for candidate in state["candidates"]:
      check candidate["heart"].kind == JInt
      check candidate["reach_seconds"].getInt > 0
      check candidate["owner"].getStr in ["ours", "enemy", "neutral"]
      check candidate["action"].getStr in ["capture", "defend"]
      check candidate["being_captured_by"].getStr in ["nobody", "us", "the enemy"]
    check state["me"]["hp_of_3"].kind == JInt
    check state["match"]["score_to_win"].getInt == 900
    check state["board"]["hearts_ours"].kind == JInt
    # The options live in the question. Restating them in the state is redundancy that the
    # earlier build paid for in string operations, and guidance does not belong in state.
    check not state.hasKey("options")
    check not state.hasKey("notes")

    # One criterion per candidate, each naming its row, plus "current" as an object.
    let criteria = questions["objective"]["criteria"]
    for i in 0 ..< state["candidates"].len:
      check criteria["C" & $i].getStr.contains("`candidates[" & $i & "]`")
    check criteria.len == state["candidates"].len + 1
    check criteria["current"].kind == JObject
    check criteria["current"]["examples"].kind == JArray

    # The narrow yes/no questions ride along in the same request, over the same state.
    for key in ["outnumbered", "heart_falling", "squad_together", "lose_life"]:
      check questions[key]["type"].getStr == "noul"
      check questions[key]["criteria"]["true"].kind == JString
      check questions[key]["criteria"]["false"].kind == JString
    # The survival question asks about losing a life, so a high probability means danger.
    check not questions.hasKey("survive")
    check questions["lose_life"]["instructions"].getStr.contains("loses one of its lives")

  test "every experiment switch combination still plays and fits the budget":
    # The shipped defaults leave several arms switched off, so nothing else here compiles the
    # code behind them. `coworld/paintbot/tools/jev_experiment.py` ships exactly these flips as
    # hosted experiment arms; a broken arm must fail here, not after a battery of paid episodes.
    const Arms = {
      "no nouls": @[("useNouls", 0)],
      "score": @[("useScore", 1)],
      "margin": @[("kMargin", 150)],
      "wide": @[("useWide", 1)],
      "no retreat or dial": @[("useRetreat", 0), ("useDial", 0)],
      "echo": @[("useEcho", 1)],
      "terrain": @[("useTerrain", 1)],
      "smart grenade": @[("useSmartGrenade", 1)],
      "spray": @[("useSpray", 1)],
      "weapons": @[("useSmartGrenade", 1), ("useSpray", 1)],
      "everything": @[("useTerrain", 1), ("useSmartGrenade", 1), ("useSpray", 1)],
      "explore": @[("useExplore", 1)],
    }
    # Git may check the file out with CRLF, so normalise before matching on line boundaries.
    let shipped = readFile(Jev).replace("\r\n", "\n")
    for (name, flips) in Arms:
      var source = shipped
      for (switch, value) in flips:
        let want = "\n  " & switch & " = " & $value & "\n"
        for old in 0..1:
          source = source.replace("\n  " & switch & " = " & $old & "\n", want)
        # The switch must exist in the init block under exactly this name, or the arm is a
        # no-op that would quietly measure the shipped defaults instead.
        check source.contains(want)
        check not source.contains("\n  " & switch & " = 0\n") or value == 0
      let path = getTempDir() / ("paintbot-jev-arm-" & name.replace(" ", "-") & ".bas")
      writeFile(path, source)
      defer: removeFile(path)

      resetOracle()
      oracleEnabled = true
      peakInstructions = default(array[Seats, int64])
      peakWork = default(array[Seats, int64])
      peakStrings = default(array[Seats, int64])
      var w = newWorld(4)
      let players = loadBots(@[BotGroup(path: path, count: Seats)])
      var asked = 0
      # 720 ticks, not 360: the terrain arm's instruction overrun only appeared after 360, so a
      # shorter run passed an arm that disables seats in a real match.
      while w.tick < 720 and w.winner == -1:
        let commands = players.decide(w)
        for ask in drainOracleAsks():
          inc asked
          # Answer whatever this arm asked, so the consume path runs too.
          var answers = initTable[string, OracleAnswer]()
          for key, question in parseJson(ask.body)["questions"]:
            answers[key] = OracleAnswer(value: 0, confidence: 900,
                probabilities: {"C0": 800'i32, "current": 200'i32}.toTable)
          deliverOracleReply(OracleReply(slot: ask.slot, id: ask.id, status: answers.len,
              answers: answers))
        deliverSpeech(w)
        w.step(commands)
      check asked > 0
      for slot in 0..<Seats:
        check not players[slot].failed
        check peakInstructions[slot] < 37_500
        check peakWork[slot] < 93_750
        check peakStrings[slot] < 768

  test "the terrain prompt describes trenches, water, supplies and nearby enemies":
    var source = readFile(Jev).replace("\r\n", "\n").replace("\n  useTerrain = 0\n", "\n  useTerrain = 1\n")
    check "  useTerrain = 1" in source
    let path = getTempDir() / "paintbot-jev-terrain.bas"
    writeFile(path, source)
    defer: removeFile(path)
    resetOracle()
    oracleEnabled = true
    var w = newWorld(4)
    let players = loadBots(@[BotGroup(path: path, count: Seats)])
    discard players.decide(w)
    let body = parseJson(drainOracleAsks()[0].body)
    let state = body["state"]
    for c in state["candidates"]:
      for field in ["nearest_trench_m", "enemies_near", "enemies_in_trenches_near",
                    "water_on_route_m", "grenade_pickup_m", "spray_pickup_m",
                    "medkit_pickup_m", "armor_pickup_m"]:
        check c.hasKey(field)
        check c[field].kind == JInt
      # A heart has a nearest trench whenever the map has trenches at all.
      check c["nearest_trench_m"].getInt >= 0
    for field in ["has_grenade", "has_spray", "armor"]:
      check state["me"].hasKey(field)
    check "Trenches are pits" in state["rules"].getStr
    check "a quarter of its speed" in state["rules"].getStr
