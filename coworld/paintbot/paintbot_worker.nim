import
  std/[json, os, strutils, uri],
  ../../examples/paintbot/game,
  ../../src/polyworld/coworld,
  ./packages

proc main() =
  ## Stages submitted policies and runs one native game without a network bridge.
  delEnv("PW_POLICY_FD")
  delEnv("PW_ORACLE")
  let
    seatPath = decodeUrl(parseUri(getEnv("COGAME_PLAYER_SEATS_URI")).path)
    directory = seatPath.parentDir
  var
    document = parseJson(readFile(seatPath))
    failures: seq[(int, string)]
  for seat in document["seats"]:
    let
      slot = seat["slot"].getInt
      sourcePath = directory / "player-" & $slot & ".bas"
      input = decodeUrl(parseUri(seat["file_uri"].getStr).path)
    var size: int
    try:
      if getFileSize(input) != seat["size_bytes"].getBiggestInt or getFileSize(input) > MaxPackageBytes:
        raise newException(ValueError, "Invalid policy size")
      size = stagePolicy(readFile(input), sourcePath)
    except CatchableError as error:
      failures.add (slot, error.msg)
      for suffix in [".model.bin", ".neural.json"]:
        if fileExists(sourcePath & suffix): removeFile(sourcePath & suffix)
      writeFile(sourcePath, "idle = 1\n")
      size = getFileSize(sourcePath).int
    seat["file_uri"] = %("file://" & encodeUrl(sourcePath, usePlus = false).replace("%2F", "/"))
    seat["size_bytes"] = %size
  let staged = directory / "staged-seats.json"
  writeFile(staged, $document)
  putEnv("COGAME_PLAYER_SEATS_URI", "file://" & staged)
  game.setup()
  for (slot, message) in failures:
    playerError(slot, "Policy initialization failed: " & message)
  game.runHeadless(initialized = true)

when isMainModule:
  main()
