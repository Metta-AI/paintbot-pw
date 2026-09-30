import
  std/[json, os, strutils, tables, tempfiles],
  zippy/ziparchives,
  ../coworld/paintbot/packages,
  ../examples/paintbot/[neural_contract, neural_host]

proc u32(data: var string, value: int) =
  ## Encodes a model header word.
  for i in 0 .. 3: data.add char((value shr (i * 8)) and 255)

proc packageBytes*(): string =
  ## Builds a valid zero-weight actor for package and API tests.
  const
    Hidden = 64
    Count = ObservationSize * Hidden + 3 * Hidden * Hidden + LogitSize * Hidden
  var model = "PWNET001"
  for value in [1, ObservationSize, Hidden, LogitSize, ActionSizes.len, Count]: model.u32(value)
  model.add ObservationContractHash & ActionContractHash
  for value in ActionSizes: model.u32(value)
  model.add repeat('\0', Count * 4)
  let source = "paintbot_observe(neuralObservation())\nrun_neural_net(neuralModel(), neuralObservation(), neuralLogits(), neuralState())\npaintbot_act(neuralLogits())\n"
  let manifest = %*{"schema": "paintbot-neural-basic/1",
    "observation_contract": ObservationContractHash, "action_contract": ActionContractHash,
    "sha256": {"policy.bas": digest(source), "model.bin": digest(model)}}
  createZipArchive({"policy.bas": source, "manifest.json": $manifest, "model.bin": model}.toOrderedTable)

proc main() =
  ## Checks package integrity, archive boundaries and native model loading.
  let root = createTempDir("paintbot-package-test-", "")
  defer: removeDir(root)
  let path = root / "policy.bas"
  let bytes = packageBytes()
  discard stagePolicy(bytes, path)
  doAssert loadNeuralSeat(path, 0).actor != nil
  if paramCount() == 1: writeFile(paramStr(1), bytes)
  let duplicate = createZipArchive({"policy.bas": "end", "policy.baX": "end"}.toOrderedTable)
    .replace("policy.baX", "policy.bas")
  var corrupt = bytes
  let central = corrupt.find("PK\x01\x02")
  doAssert central >= 0
  corrupt[central + 16] = char(ord(corrupt[central + 16]) xor 1)
  for bad in ["PK\x03\x04broken", duplicate, corrupt,
      createZipArchive({"../policy.bas": "end"}.toOrderedTable),
      createZipArchive({"policy.bas": repeat('x', MaxSourceBytes + 1)}.toOrderedTable),
      createZipArchive({"policy.bas": "end", "model.bin": "bad", "manifest.json": "{}"}.toOrderedTable)]:
    var failed = false
    try: discard stagePolicy(bad, path)
    except CatchableError: failed = true
    doAssert failed
  doAssert stagePolicy("idle = 1\n", root / "raw.bas") == 9

when isMainModule:
  main()
