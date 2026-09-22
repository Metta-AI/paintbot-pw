import std/[unittest, os, strutils]
import polyworld/cli
import ../examples/paintbot/[bots, sim, neural_contract, neural_host]

proc u32(s: var string, value: uint32) =
  for i in 0..3: s.add char((value shr (8*i)) and 255)
proc zeroModel(actionContract = ActionContractHash): string =
  const h = 64
  const n = ObservationSize*h + 3*h*h + LogitSize*h
  result = "PWNET001"
  for x in [1,ObservationSize,h,LogitSize,ActionSizes.len,n]: result.u32(x.uint32)
  result.add ObservationContractHash
  result.add actionContract
  for x in ActionSizes: result.u32(x.uint32)
  result.add repeat('\0', n*4)

const NeuralSource = """
paintbot_observe(neuralObservation())
run_neural_net(neuralModel(), neuralObservation(), neuralLogits(), neuralState())
paintbot_act(neuralLogits())
"""
proc fixture(source: string, model = true, actionContract = ActionContractHash): array[Seats,Bot] =
  let path = getTempDir()/"paintbot-neural-host-test.bas"
  writeFile(path,source)
  if model: writeFile(path & ".model.bin", zeroModel(actionContract))
  defer:
    removeFile(path)
    if fileExists(path & ".model.bin"): removeFile(path & ".model.bin")
  loadBots(@[BotGroup(path:path,count:Seats)])
proc mixedFixture(): array[Seats,Bot] =
  ## Slot 0 runs the neural package; every other seat is plain BASIC.
  let neuralPath = getTempDir()/"paintbot-neural-host-test-neural.bas"
  let plainPath = getTempDir()/"paintbot-neural-host-test-plain.bas"
  writeFile(neuralPath, NeuralSource)
  writeFile(neuralPath & ".model.bin", zeroModel())
  writeFile(plainPath, "walkTo(selfX,selfY)\n")
  defer:
    removeFile(neuralPath)
    removeFile(neuralPath & ".model.bin")
    removeFile(plainPath)
  loadBots(@[BotGroup(path:neuralPath,count:1), BotGroup(path:plainPath,count:Seats-1)])

suite "native BASIC neural host":
  test "seat buffers are independent and recurrence resets on death and match reset":
    let players = fixture(NeuralSource)
    var w = newWorld(2026)
    discard players.decide(w)
    check not players[0].failed
    check players[0].neural.nativeWork > 0
    check peakNativeWork[0] == players[0].neural.nativeWork
    check players[0].neural.state[0] == 0.25'f32
    players[0].neural.state[0] = 42
    check players[1].neural.state[0] == 0.25'f32
    w.tick = 1
    w.cogs[0].hp = 0
    discard players.decide(w)
    check players[0].neural.state[0] == 0
    w.tick = 2
    w.cogs[0].hp = 3
    discard players.decide(w)
    check players[0].neural.state[0] == 0.25'f32
    players[0].neural.state[0] = 42
    w.tick = 0
    discard players.decide(w)
    check players[0].neural.state[0] == 0.25'f32

  test "repeated inference fails seat and discards commands":
    let players = fixture(NeuralSource & "run_neural_net(1,2,3,4)\n")
    let commands = players.decide(newWorld(2026))
    check players[0].failed
    check not commands[0].walk and not commands[0].shoot

  test "wrong typed handles fail explicitly":
    let players = fixture("paintbot_observe(neuralState())\n")
    discard players.decide(newWorld(2026))
    check players[0].failed

  test "plain BASIC remains supported and missing model fails explicitly":
    let plain = fixture("walkTo(selfX,selfY)\n",false)
    discard plain.decide(newWorld(2026))
    check not plain[0].failed
    let missing = fixture(NeuralSource,false)
    discard missing.decide(newWorld(2026))
    check missing[0].failed

  test "seat telemetry line names peak operations, budget, width and ticks":
    check neuralTelemetry(238080, 128, 1200) ==
      "neural: peak_ops=238080 budget=4000000 model=w128 ticks=1200"

  test "seat telemetry is logged for neural seats and not for plain seats":
    let players = mixedFixture()
    var w = newWorld(2026)
    discard players.decide(w)
    w.tick = 1
    discard players.decide(w)
    check not players[0].failed and not players[1].failed
    let expected = int64(2*(ObservationSize*64 + 3*64*64 + LogitSize*64) + 32*64)
    check players[0].neural.nativeWork == expected
    var lines: seq[(int, string)]
    players.logNeuralTelemetry(2, proc(slot: int, text: string) = lines.add((slot, text)))
    check lines.len == 1
    check lines[0][0] == 0
    check lines[0][1] == "neural: peak_ops=" & $expected & " budget=4000000 model=w64 ticks=2\n"
    # A plain seat logs nothing, and the world is untouched by telemetry.
    let before = w.stateHash()
    players.logNeuralTelemetry(2, proc(slot: int, text: string) = discard)
    check w.stateHash() == before

  test "the bundle's action contract hash selects the decoder; unknown hashes are rejected":
    let v1 = fixture(NeuralSource)
    check v1[0].neural.contract == acV1
    let v2 = fixture(NeuralSource, true, ActionContractV2Hash)
    check v2[0].neural.contract == acV2
    var w = newWorld(2026)
    discard v2.decide(w)
    check not v2[0].failed
    check v2[0].neural.memory.tick == w.tick # v2 records its aim memory after acting
    discard v1.decide(w)
    check not v1[0].failed
    check v1[0].neural.memory.tick == -1 # v1 never touches it
    let unknown = fixture(NeuralSource, true, "0" & ActionContractV2Hash[1..^1])
    discard unknown.decide(w)
    check unknown[0].failed
