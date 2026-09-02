import
  std/os,
  polyworld/[cli, controllers]

echo "Testing --player:2 marks the second slot"
block:
  let kinds = controllerKinds(4, 2)
  doAssert kinds.len == 4
  doAssert kinds[0] == BotController
  doAssert kinds[1] == PlayerController
  doAssert kinds[2] == BotController
  doAssert kinds[3] == BotController
  doAssert isPlayerIndex(2, 1)
  doAssert not isPlayerIndex(2, 0)
  doAssert not isPlayerIndex(0, 0)

echo "Testing bots expand around the human slot"
block:
  let
    path = getTempDir() / "polyworld_controller_bot.bas"
    kinds = controllerKinds(4, 2)
  writeFile(path, "PRINT 1\n")
  var groups: seq[BotGroup]
  groups.addBotSpec(path & ":3")
  let sources = groups.expandBotSources(kinds)
  doAssert sources.len == 4
  doAssert sources[0] == "PRINT 1\n"
  doAssert sources[1].len == 0
  doAssert sources[2] == "PRINT 1\n"
  doAssert sources[3] == "PRINT 1\n"
  removeFile(path)

echo "Controller tests passed"
