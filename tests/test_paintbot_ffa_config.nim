## The FFA-kin mode is chosen by the coworld config's optional "mode" key; absent means teams.
## The optional "kin_layout" key (FFA-kin only) pins every match to one family layout.
import std/[unittest, json]
import polyworld/cli
import ../examples/paintbot/[sim, game, kinship]

suite "game mode config":
  test "teams is the default":
    check gameMode == gmTeams
    check not ffa()

  test "parseGameMode reads the mode key":
    check parseGameMode(%*{"seed": 1}) == gmTeams
    check parseGameMode(%*{"mode": "teams"}) == gmTeams
    check parseGameMode(%*{"mode": "ffa_kin"}) == gmFfaKin
    expect ValueError: discard parseGameMode(%*{"mode": "ffa"})
    expect ValueError: discard parseGameMode(%*{"mode": 3})

  test "applyGameConfig sets the mode and caps an FFA match at six minutes":
    game.options = GameOptions(seed: 1, maximumTicks: 14400)
    applyGameConfig("""{"seed": 1, "max_ticks": 14400, "mode": "ffa_kin"}""")
    check gameMode == gmFfaKin
    check ffa()
    check game.options.maximumTicks == FfaMatchTicks
    game.options.maximumTicks = 2400
    applyGameConfig("""{"mode": "ffa_kin"}""")
    check game.options.maximumTicks == 2400
    game.options.maximumTicks = 14400
    applyGameConfig("""{"seed": 1}""")
    check gameMode == gmTeams
    check game.options.maximumTicks == 14400

suite "kin layout config":
  test "parseKinLayout reads every layout name and defaults to sampled":
    check parseKinLayout(%*{"mode": "ffa_kin"}, gmFfaKin).isNone
    check parseKinLayout(%*{"mode": "ffa_kin", "kin_layout": "sampled"}, gmFfaKin).isNone
    let names = {"fours": klFours, "pairs": klPairs, "trios_loner": klTriosLoner,
      "cousins": klCousins, "strangers": klStrangers, "clones": klClones,
      "tribes": klTribes}
    for (name, layout) in names:
      check parseKinLayout(%*{"mode": "ffa_kin", "kin_layout": name}, gmFfaKin) == some(layout)
    expect ValueError: discard parseKinLayout(%*{"kin_layout": "triples"}, gmFfaKin)
    expect ValueError: discard parseKinLayout(%*{"kin_layout": 3}, gmFfaKin)
    expect ValueError: discard parseKinLayout(%*{"kin_layout": "cousins"}, gmTeams)
    expect ValueError: discard parseKinLayout(%*{"kin_layout": "sampled"}, gmTeams)
    check parseKinLayout(%*{"seed": 1}, gmTeams).isNone

  test "applyGameConfig sets the pin and rejects kin_layout in the teams game":
    game.options = GameOptions(seed: 1, maximumTicks: 14400)
    applyGameConfig("""{"mode": "ffa_kin", "kin_layout": "cousins"}""")
    check kinLayoutPin == some(klCousins)
    applyGameConfig("""{"mode": "ffa_kin"}""")
    check kinLayoutPin.isNone
    expect ValueError: applyGameConfig("""{"kin_layout": "cousins"}""")
    expect ValueError: applyGameConfig("""{"mode": "teams", "kin_layout": "fours"}""")
    applyGameConfig("""{"seed": 1}""")
    check gameMode == gmTeams
    check kinLayoutPin.isNone

  test "a pinned layout plays that layout on every seed, with seeded families":
    game.options = GameOptions(seed: 1, maximumTicks: 14400)
    applyGameConfig("""{"mode": "ffa_kin", "kin_layout": "cousins"}""")
    var families: seq[seq[int8]]
    for seed in 1'i32..50'i32:
      let w = newLiveWorld(seed, 240)
      discard w
      check activeKinship.layout == klCousins
      check activeKinship == kinshipFor(klCousins, seed)
      check matchKinship(seed).layout == klCousins
      if activeKinship.family notin families: families.add activeKinship.family
    check families.len > 40
    applyGameConfig("""{"mode": "ffa_kin"}""")
    var layouts: set[KinLayout]
    for seed in 1'i32..50'i32:
      discard newLiveWorld(seed, 240)
      check activeKinship == sampleKinship(seed)
      layouts.incl activeKinship.layout
    check layouts.card > 1
    applyGameConfig("""{"seed": 1}""")
