## `players/jev.bas` is the BASIC baseline with the Jev advisor layer spliced in by
## `coworld/paintbot/tools/make_jev_baseline.py`. Where no oracle is configured (certification
## pods, this suite) every ask is refused, and the file must then play exactly like `base.bas`:
## the same state hash tick for tick, no seat disabled, and a per-decision cost that stays well
## inside the BASIC budget even though it drafts oracle requests.
import std/[unittest, os, strutils, tables]
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
    # Limits are 20,000 instructions, 50,000 work units and 1,024 string handles per decision;
    # measured peaks are about 12,600 / 26,700 / 131. Guard three quarters of each limit.
    let (_, players) = play(Jev, 4, advised = true)
    check drainOracleAsks().len > 0
    for slot in 0..<Seats:
      check not players[slot].failed
      check peakInstructions[slot] < 15_000
      check peakWork[slot] < 37_500
      check peakStrings[slot] < 768

  test "Jev's pick is relayed as a squad callout that squadmates decode":
    # An answered ask makes the asker shout "<Squad>, push <Heart>." (or hold / carry on) every
    # two seconds; the heart's name starts with A + its index. Squadmates within earshot adopt
    # it and log "relay ... obj=<heart> kind=<kind>". Nothing shouts the old "jev 0 5 0" form.
    const Names = ["Anvil", "Bridge", "Chapel", "Dock", "Elm", "Forge", "Gate", "Hollow", "Inn",
        "Jetty", "Kiln", "Lookout", "Mill", "Nook", "Orchard", "Pier"]
    resetOracle()
    oracleEnabled = true
    var w = newWorld(4)
    var players = loadBots(@[BotGroup(path: Jev, count: Seats)])
    var lines: array[Seats, string]
    var relays: seq[tuple[tick, slot, heart, kind: int]]
    proc printer(s: int): PrintProc =
      # A proc per slot: a closure made in a loop body would share one captured `slot`.
      result = proc(e: PrintEvent) =
        case e.kind
        of TextPrint: lines[s].add e.text
        of ValuePrint: lines[s].add $e.value
        of NewlinePrint:
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
