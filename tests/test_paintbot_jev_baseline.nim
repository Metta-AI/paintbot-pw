## `players/jev.bas` is the BASIC baseline with the Jev advisor layer spliced in by
## `coworld/paintbot/tools/make_jev_baseline.py`. Where no oracle is configured (certification
## pods, this suite) every ask is refused, and the file must then play exactly like `base.bas`:
## the same state hash tick for tick, no seat disabled, and a per-decision cost that stays well
## inside the BASIC budget even though it drafts oracle requests.
import std/[unittest, os]
import polyworld/[cli, basic]
import ../examples/paintbot/[sim, bots, oracle]

const Ticks = 720   # thirty seconds: the layer's first asks, shouts and heart flips all fall inside
const Root = currentSourcePath().parentDir.parentDir
const Base = Root / "coworld/paintbot/players/base.bas"
const Jev = Root / "coworld/paintbot/players/jev.bas"

proc play(path: string, seed: int32): (seq[uint32], array[Seats, Bot]) =
  resetOracle()
  oracleEnabled = false
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
    # Limits are 20,000 instructions, 50,000 work units and 1,024 string handles per decision;
    # measured peaks are about 10,300 / 14,500 / 22. Guard three quarters of each limit.
    discard play(Jev, 4)
    for slot in 0..<Seats:
      check peakInstructions[slot] < 15_000
      check peakWork[slot] < 37_500
      check peakStrings[slot] < 768
