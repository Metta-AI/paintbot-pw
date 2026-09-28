## The FFA-kin mode is chosen by the coworld config's optional "mode" key; absent means teams.
import std/[unittest, json]
import polyworld/cli
import ../examples/paintbot/[sim, game]

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
    options = GameOptions(seed: 1, maximumTicks: 14400)
    applyGameConfig("""{"seed": 1, "max_ticks": 14400, "mode": "ffa_kin"}""")
    check gameMode == gmFfaKin
    check ffa()
    check options.maximumTicks == FfaMatchTicks
    options.maximumTicks = 2400
    applyGameConfig("""{"mode": "ffa_kin"}""")
    check options.maximumTicks == 2400
    options.maximumTicks = 14400
    applyGameConfig("""{"seed": 1}""")
    check gameMode == gmTeams
    check options.maximumTicks == 14400
