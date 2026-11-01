## First RED tracer only: a complete synthetic replay, no controllers or private fixtures.
## Proposed trusted in-process seam: configureReplayDebugger(path, engine).
## The executable must use read-only fd 3 instead; neither path nor trusted engine
## configuration is accepted from request JSON. PW_DEBUG_SESSION_ID is launcher state.
{.define: replayDebuggerStrict.}
import std/[unittest, os, osproc, strutils, json, tempfiles]
import ../examples/paintbot/[sim, game, kinship]
import ../examples/paintbot/replay_debugger
import ../examples/paintbot/analysis

const
  Protocol = "paintbot_replay_debugger_v1"
  SessionId = "synthetic_replay_tracer"
  Root = currentSourcePath().parentDir.parentDir
  EndTick = 24

proc sha256File(path: string): string =
  let (output, status) = execCmdEx("sha256sum -- " & quoteShell(path))
  doAssert status == 0, output
  result = output.splitWhitespace()[0]
  doAssert result.len == 64

proc request(id, verb: string, params: JsonNode): JsonNode =
  %*{"schema_version": Protocol, "operation_id": id,
     "method": verb, "params": params}

proc successful(req: JsonNode): JsonNode =
  let response = handleRequest(req)
  doAssert response.kind == JObject
  doAssert response.len == 9
  doAssert response["schema_version"] == %Protocol
  doAssert response["operation_id"] == req["operation_id"]
  doAssert response["method"] == req["method"]
  doAssert response["status"] == %"ok", $response
  doAssert response["publication_authorized"] == %false
  doAssert response["faults"] == newJArray()
  doAssert response["provenance"].kind == JArray
  doAssert response["evidence_refs"].kind == JArray
  response["data"]

proc assertSession(session, engine: JsonNode, tick: int) =
  doAssert session.len == 9
  doAssert session["session_id"] == %SessionId
  doAssert session["backend"] == %"replay"
  doAssert session["engine"] == engine
  doAssert session["tick"] == %tick
  doAssert session["phase"] == %"historical"
  doAssert session["capabilities"] == %*["replay_inspect"]
  doAssert session["visibility"] == %"seat"
  doAssert session["verification"] == %"verified"
  doAssert session["terminal"] == %false

suite "public replay debugger first tracer":
  test "index event mapping uses source ticks and honest classifications":
    var index: ReplayIndex
    index.hits = @[Moment(tick: 8, slot: 2, kind: "hit")]
    index.events = @[Moment(tick: 9, slot: 3, kind: "grenade pickup"),
      Moment(tick: 10, slot: 4, kind: "shield pickup"),
      Moment(tick: 11, slot: 5, kind: "spray pickup")]
    index.heartTenures = @[@[HeartTenure(tick: 0, owner: -1), HeartTenure(tick: 12, owner: 0), HeartTenure(tick: 13, owner: -1)]]
    let rows = debuggerEvents(index)
    check rows.len == 6
    check rows[0]["tick"] == %7
    check rows[0]["event_type"] == %"hit"
    check rows[0]["classification"] == %"observed"
    for i in 1..3:
      check rows[i]["event_type"] == %"equipment_net_increase"
      check rows[i]["classification"] == %"inferred"
    for i in 4..5:
      check rows[i]["event_type"] == %"heart_owner_change"
      check rows[i]["classification"] == %"inferred"
      check rows[i]["seat"].kind == JNull
    check rows[5]["tick"] == %12
  test "open and seek expose recorded pre-step state through seat inspection":
    let directory = createTempDir("paintbot-debugger-", "")
    defer: removeDir(directory)
    let replayPath = directory / "synthetic.replay"
    let configPath = directory / "config.json"
    let previousSession = getEnv("PW_DEBUG_SESSION_ID")
    let hadSession = existsEnv("PW_DEBUG_SESSION_ID")
    putEnv("PW_DEBUG_SESSION_ID", SessionId)
    defer:
      if hadSession: putEnv("PW_DEBUG_SESSION_ID", previousSession)
      else: delEnv("PW_DEBUG_SESSION_ID")

    configureSeats(16)
    gameMode = gmTeams
    replayRulesVersion = LiveRules
    configureRules(LiveRules)
    configureMap("highlands")
    configureVision("")
    configureVisionRange(0)
    configureGlory(DefaultGloryConfig)
    var generated = Recording(seed: 17, endTick: EndTick, seats: Seats.int32,
      map: "highlands", vision: "", glory: DefaultGloryConfig,
      names: newSeq[string](Seats))
    for i in 0..<Seats: generated.names[i] = "Synthetic " & $i
    var simulated = newWorld(generated.seed, generated.endTick)
    var hashes = @[simulated.stateHash()]
    var positions = @[simulated.cogs[0].pos]
    var health = @[simulated.cogs[0].hp]
    while simulated.tick < EndTick and simulated.winner == -1:
      var commands = newSeq[Command](Seats)
      for i in 0..<Seats:
        commands[i] = Command(walk: true, goal: home(1-team(i)),
          shoot: true, aim: home(1-team(i)), selfDestruct: simulated.tick == 10 and i == 0)
      simulated.step(commands, LiveRules)
      generated.frames.add Frame(commands: commands, hash: simulated.stateHash())
      hashes.add simulated.stateHash()
      positions.add simulated.cogs[0].pos
      health.add simulated.cogs[0].hp
    require simulated.tick == EndTick
    require simulated.winner != -1
    require generated.frames.len == EndTick
    saveRecording(replayPath, generated)

    # Actual local artifact digests, never placeholder provenance. This executable
    # embeds the worker for this test; its digest is not a hosted engine identity.
    writeFile(configPath, "{\"end_tick\":24,\"map\":\"highlands\",\"seats\":16,\"seed\":17}")
    let (revision, gitStatus) = execCmdEx("git -C " & quoteShell(Root) & " rev-parse HEAD")
    require gitStatus == 0
    let engine = %*{
      "repository_sha": revision.strip(),
      "executable_sha256": sha256File(getAppFilename()),
      "container_digest": nil,
      "dependency_lock_sha256": sha256File(Root / "coworld/dependencies.lock"),
      "config_sha256": sha256File(configPath),
      "map_sha256": sha256File(Root / "examples/paintbot/maps/highlands.pbmap"),
      "rules_version": LiveRules, "observation_version": "seat_view",
      "replay_version": replayGameVersion().int,
      "coworld_id": nil, "manifest_sha256": nil, "identity_strength": "exact_local"}
    let exportDir = getEnv("PW_TEST_FIXTURE_DIR")
    if exportDir.len > 0:
      createDir(exportDir)
      copyFile(replayPath, exportDir / "synthetic.replay")
      copyFile(configPath, exportDir / "config.json")
      var exportedEngine = engine.copy()
      exportedEngine["executable_sha256"] = %sha256File(getEnv("PW_TEST_REPLAY_DEBUGGER"))
      var exportedHashes = newJArray()
      for hash in hashes: exportedHashes.add %($hash)
      writeFile(exportDir / "metadata.json", $(%*{"session_id": SessionId,
        "artifact_sha256": sha256File(replayPath), "engine": exportedEngine,
        "end_tick": EndTick, "world_hashes": exportedHashes}))
      require fileExists(exportDir / "synthetic.replay")
      let exported = parseFile(exportDir / "metadata.json")
      check exported["artifact_sha256"] == %sha256File(exportDir / "synthetic.replay")
      check exported["engine"]["executable_sha256"] == %sha256File(getEnv("PW_TEST_REPLAY_DEBUGGER"))
      check exported["world_hashes"].len == hashes.len

    configureReplayDebugger(replayPath, engine)
    let opened = successful(request("open_tracer", "open", %*{
      "artifact_sha256": sha256File(replayPath), "engine": engine}))
    assertSession(opened, engine, 0)
    # Tick 12 means frames [0,12) have run; the recorded next action has not.
    let sought = successful(request("seek_tracer", "seek", %*{"tick": 12}))
    assertSession(sought, engine, 12)
    let inspected = successful(request("inspect_tracer", "inspect", %*{
      "session_id": SessionId, "seat": 0, "entity_id": 0, "lens": "seat",
      "fields": ["tick", "world_hash", "position", "hp"]}))
    assertSession(inspected["session"], engine, 12)
    check inspected["seat"] == %0
    check inspected["entity_id"] == %0
    let expected = %*{
      "tick": 12, "world_hash": $hashes[12],
      "position": {"x": positions[12].x, "z": positions[12].z}, "hp": health[12]}
    var seen = newJObject()
    for row in inspected["values"]:
      let field = row["field"].getStr()
      require expected.hasKey(field)
      require not seen.hasKey(field)
      check row["missing_reason"].kind == JNull
      check row["value"] == expected[field]
      seen[field] = row["value"]
    check seen == expected

    # Slice 2: refuse unverified bytes, bindings and incomplete histories.
    template refusedOpen(code: string) =
      configureReplayDebugger(replayPath, engine) # fresh isolated worker seam
      let reply = handleRequest(request("bad_open", "open", %*{
        "artifact_sha256": sha256File(replayPath), "engine": engine}))
      check reply["status"] == %"error"
      check reply["data"].kind == JNull
      check reply["faults"][0]["code"] == %code
    let wrongDigest = handleRequest(request("bad_digest", "open", %*{
      "artifact_sha256": repeat('0', 64), "engine": engine}))
    check wrongDigest["status"] == %"error"
    var otherEngine = engine.copy()
    otherEngine["rules_version"] = %1
    check handleRequest(request("bad_engine", "open", %*{
      "artifact_sha256": sha256File(replayPath), "engine": otherEngine}))["status"] == %"error"
    generated.frames[^1].hash = generated.frames[^1].hash xor 1
    saveRecording(replayPath, generated)
    refusedOpen("verification_failed")
    generated.frames[^1].hash = generated.frames[^1].hash xor 1
    let finalFrame = generated.frames.pop()
    saveRecording(replayPath, generated)
    refusedOpen("verification_failed")
    generated.frames.add finalFrame
    saveRecording(replayPath, generated)
    discard successful(request("reopen", "open", %*{
      "artifact_sha256": sha256File(replayPath), "engine": engine}))

    # Slice 3: bounded navigation, terminal/pure inspection and close.
    for target in [EndTick, 3, 18, 0]:
      let s = successful(request("seek_again", "seek", %*{"tick": target}))
      check s["tick"] == %target
      check s["terminal"] == %(target == EndTick)
      check world.stateHash() == hashes[target]
    for tick in [%(-1), %(EndTick+1), %true, %1.0]:
      check handleRequest(request("bad_seek", "seek", %*{"tick": tick}))["status"] == %"error"
      check world.stateHash() == hashes[0]
    let pureRequest = request("pure", "inspect", %*{
      "session_id": SessionId, "seat": 0, "entity_id": 0, "lens": "seat",
      "fields": ["terminal", "visible", "team", "observation", "variables"]})
    let pure = successful(pureRequest)
    check successful(pureRequest) == pure
    check world.stateHash() == hashes[0]
    check pure["values"][0]["value"] == %false
    check pure["values"][1]["value"] == %true
    check pure["values"][2]["value"] == %0
    for i in 3..4:
      check pure["values"][i]["value"].kind == JNull
      check pure["values"][i]["missing_reason"] == %"not_captured"
    for i in 0..1:
      check successful(request("close", "close", %*{})) == %*{"session_id": SessionId, "closed": true}
    check handleRequest(pureRequest)["status"] == %"error"

    # Slice 4: frozen request shapes and seat visibility.
    configureReplayDebugger(replayPath, engine)
    discard successful(request("open_four", "open", %*{
      "artifact_sha256": sha256File(replayPath), "engine": engine}))
    for bad in [request("extra", "seek", %*{"tick": 0, "path": "/etc/passwd"}),
                request("missing", "seek", %*{}),
                request("unknown", "step", %*{}),
                request("bad_id", "inspect", %*{"session_id": "other", "seat": 0,
                  "entity_id": 0, "lens": "seat", "fields": ["hp"]}),
                request("bad_seat", "inspect", %*{"session_id": SessionId, "seat": true,
                  "entity_id": 0, "lens": "seat", "fields": ["hp"]})]:
      check handleRequest(bad)["status"] == %"error"
    let hidden = successful(request("hidden", "inspect", %*{
      "session_id": SessionId, "seat": 0, "entity_id": 1, "lens": "seat",
      "fields": ["visible", "position", "hp", "team"]}))
    check hidden["session"]["visibility"] == %"seat"
    check hidden["values"][0]["value"] == %false
    for i in 1..3:
      check hidden["values"][i]["value"].kind == JNull
      check hidden["values"][i]["missing_reason"] == %"not_visible"

    # Slice 8: scores are match glory, nullable selectors are global-only.
    let global = successful(request("global", "inspect", %*{
      "session_id": SessionId, "seat": 0, "entity_id": nil, "lens": "seat",
      "fields": ["scores", "hp"]}))
    check global["values"][0]["value"] == %*[{"side": 0, "value": world.scores()[0]}, {"side": 1, "value": world.scores()[1]}]
    check global["values"][1]["missing_reason"] == %"not_applicable"
    let omni = request("omni", "inspect", %*{"session_id": SessionId,
      "seat": nil, "entity_id": 1, "lens": "omniscient", "fields": ["position", "visible"]})
    delEnv("PW_DEBUG_ALLOW_OMNISCIENT")
    check handleRequest(omni)["status"] == %"error"
    putEnv("PW_DEBUG_ALLOW_OMNISCIENT", "1")
    let allSeeing = successful(omni)
    check allSeeing["values"][0]["value"] == %*{"x": world.cogs[1].pos.x, "z": world.cogs[1].pos.z}
    check allSeeing["values"][1]["value"] == %true
    check allSeeing["session"]["visibility"] == %"omniscient"
    var sameSelector = omni.copy()
    sameSelector["params"]["seat"] = %0
    let selectedOmni = successful(sameSelector)
    check selectedOmni["session"]["visibility"] == %"omniscient"
    check selectedOmni["values"] == allSeeing["values"]
    delEnv("PW_DEBUG_ALLOW_OMNISCIENT")

    # Slice 9: source-tick events, immutable cursor filters, pure pagination.
    var eventParams = %*{"session_id": SessionId, "start_tick": 0, "end_tick": EndTick,
      "event_types": ["shot", "down"], "cursor": nil, "limit": 1}
    check handleRequest(request("events_denied", "events", eventParams))["status"] == %"error"
    putEnv("PW_DEBUG_ALLOW_OMNISCIENT", "1")
    let firstPage = successful(request("events_first", "events", eventParams))
    require firstPage["events"].len == 1
    require firstPage["cursor"].kind == JString
    var altered = eventParams.copy()
    altered["cursor"] = firstPage["cursor"]
    altered["start_tick"] = %1
    check handleRequest(request("cursor_filter", "events", altered))["status"] == %"error"
    for (key, value) in [("session_id", %"other_session"), ("end_tick", %(EndTick-1)),
        ("event_types", %*["down"]), ("limit", %2)]:
      altered = eventParams.copy()
      altered["cursor"] = firstPage["cursor"]
      altered[key] = value
      check handleRequest(request("cursor_changed", "events", altered))["status"] == %"error"
      check world.stateHash() == hashes[0]
    for cursor in [%true, %1, %1.0, %"bad", %(firstPage["cursor"].getStr().split(':')[0] & ":-1"),
        %(firstPage["cursor"].getStr().split(':')[0] & ":999999999999999999999999")]:
      altered = eventParams.copy()
      altered["cursor"] = cursor
      check handleRequest(request("cursor_invalid", "events", altered))["status"] == %"error"
    for key in ["start_tick", "end_tick"]:
      for value in [%true, %1.0, %(-1), %28801, newJNull()]:
        altered = eventParams.copy()
        altered[key] = value
        check handleRequest(request("range_invalid", "events", altered))["status"] == %"error"
    var count = 0
    var downs = 0
    while true:
      let page = successful(request("event_page", "events", eventParams))
      for event in page["events"]:
        inc count
        check event["classification"] == %"observed"
        if event["event_type"] == %"down":
          inc downs
          check event["tick"] == %10
      eventParams["cursor"] = page["cursor"]
      if page["cursor"].kind == JNull: break
      require count < 1000
    check count > 16
    check downs == 1
    check world.stateHash() == hashes[0]
    for limit in [%0, %257, %true, %1.0]:
      altered = eventParams.copy()
      altered["limit"] = limit
      check handleRequest(request("event_limit", "events", altered))["status"] == %"error"
    delEnv("PW_DEBUG_ALLOW_OMNISCIENT")

    # Slice 5: exercise a separately compiled ordinary fd3 JSONL executable.
    let worker = getEnv("PW_TEST_REPLAY_DEBUGGER")
    require worker.len > 0
    putEnv("PW_DEBUG_ENGINE_BINDING", $engine)
    defer: delEnv("PW_DEBUG_ENGINE_BINDING")
    let inputPath = directory / "requests.jsonl"
    writeFile(inputPath, $request("wire_open", "open", %*{
      "artifact_sha256": sha256File(replayPath), "engine": engine}) & "\n" &
      $request("wire_seek", "seek", %*{"tick": EndTick}) & "\n" &
      "{\"schema_version\":\"paintbot_replay_debugger_v1\",\"operation_id\":\"dup\",\"method\":\"seek\",\"params\":{\"tick\":0,\"tick\":1}}\n" &
      "{}\n" &
      "\xEF\xBB\xBF{}\n\xFF\n{} {}\n" &
      repeat('[', 34) & "0" & repeat(']', 34) & "\n" &
      "{\"a\":1e999}\n{\"a\":NaN}\n{\"a\":Infinity}\n" &
      repeat(' ', 1048577) & "\n" &
      $request("wire_recover", "seek", %*{"tick": 0}) & "\n" &
      $request("unterminated", "close", %*{}))
    let (output, status) = execCmdEx(quoteShell(worker) & " 3<" & quoteShell(replayPath) &
      " <" & quoteShell(inputPath))
    require status == 0
    let lines = output.strip().splitLines()
    require lines.len == 14
    check parseJson(lines[0])["status"] == %"ok"
    check parseJson(lines[1])["data"]["terminal"] == %true
    for i in 2..11:
      check parseJson(lines[i])["status"] == %"error"
    check parseJson(lines[12])["data"]["tick"] == %0
    check parseJson(lines[13])["status"] == %"error"

    # Slice 6: malformed roots and identifiers cannot escape or be echoed as success.
    for bad in [newJNull(), newJArray(), %*{},
        request("INVALID", "close", %*{}),
        request("bad_type", "close", %*{})]:
      var input = bad.copy()
      if input.kind == JObject and input.hasKey("operation_id") and input["operation_id"] == %"bad_type":
        input["method"] = %42
      check handleRequest(input)["status"] == %"error"

    # Slice 10: a successful worker session cannot be reopened, even after close.
    check handleRequest(request("second_open", "open", %*{
      "artifact_sha256": sha256File(replayPath), "engine": engine}))["status"] == %"error"
    discard successful(request("close_once", "close", %*{}))
    check handleRequest(request("after_close", "open", %*{
      "artifact_sha256": sha256File(replayPath), "engine": engine}))["status"] == %"error"

    # Slice 11: malformed digest types, decoded byte and tick bounds.
    configureReplayDebugger(replayPath, engine)
    for badDigest in [%true, %42, %"bad", %repeat('A', 64)]:
      let reply = handleRequest(request("digest_shape", "open", %*{"artifact_sha256": badDigest, "engine": engine}))
      check reply["faults"][0]["code"] == %"invalid"
    generated.endTick = 28801
    saveRecording(replayPath, generated)
    # Loader rejects duration bounds before returning a Recording.
    refusedOpen("verification_failed")
    generated.endTick = EndTick
    writeFile(replayPath, repeat('x', 67108865))
    refusedOpen("resource_limit")
    saveRecording(replayPath, generated)
    configureReplayDebugger(replayPath, engine)
    discard successful(request("parser_open", "open", %*{"artifact_sha256": sha256File(replayPath), "engine": engine}))
    for raw in ["NaN", "Infinity", "1e999", "\xEF\xBB\xBF{}", "\xFF", repeat('[', 34) & "0" & repeat(']', 34), "{} {}", repeat(' ', 1048577)]:
      check handleLine(raw)["status"] == %"error"

    # Slice 12: output size must refuse rather than emit oversized success.
    var hugeEngine = engine.copy()
    hugeEngine["observation_version"] = %repeat('x', 1048576)
    configureReplayDebugger(replayPath, hugeEngine)
    discard successful(request("huge_open", "open", %*{"artifact_sha256": sha256File(replayPath), "engine": hugeEngine}))
    let bounded = handleLine($request("huge_seek", "seek", %*{"tick": 0}))
    check bounded["status"] == %"error"
    check bounded["faults"][0]["code"] == %"resource_limit"
    check ($bounded).len < 1048576

    # Strict wire numbers must be checked even in trusted-binding fields.
    var numericEngine = engine.copy()
    numericEngine["observation_version"] = %"replace_number"
    configureReplayDebugger(replayPath, numericEngine)
    let numericWire = $request("numeric", "open", %*{"artifact_sha256": sha256File(replayPath), "engine": numericEngine})
    for token in ["NaN", "Infinity", "-Infinity", "1e999"]:
      check handleLine(numericWire.replace("\"replace_number\"", token))["faults"][0]["code"] == %"invalid"

    # Malformed trusted version metadata must also fail closed without a defect.
    for badBinding in [newJNull(), %true, %*[], %*{}, %*{"rules_version": true, "replay_version": 49}]:
      configureReplayDebugger(replayPath, badBinding)
      let bad = handleRequest(request("bad_binding_type", "open", %*{"artifact_sha256": sha256File(replayPath), "engine": badBinding}))
      check bad["status"] == %"error"
      check bad["faults"][0]["code"] == %"verification_failed"

    # Binary/header and bounded-count refusals happen before indexing.
    let validBytes = readFile(replayPath)
    # A valid prefix plus trailing binary junk is not a valid complete artifact.
    writeFile(replayPath, validBytes & "trailing-junk")
    refusedOpen("verification_failed")
    for cut in [0, 10, 20, validBytes.len-1]:
      writeFile(replayPath, validBytes[0..<cut])
      refusedOpen("verification_failed")
    for offset in [14, 16, 20]: # envelope, game version, game identity
      var changed = validBytes
      changed[offset] = char(ord(changed[offset]) xor 127)
      writeFile(replayPath, changed)
      refusedOpen("verification_failed")
    writeFile(replayPath, validBytes)
    for key in ["rules_version", "replay_version"]:
      var wrongVersion = engine.copy()
      wrongVersion[key] = %999
      configureReplayDebugger(replayPath, wrongVersion)
      check handleRequest(request("wrong_version", "open", %*{"artifact_sha256": sha256File(replayPath), "engine": wrongVersion}))["faults"][0]["code"] == %"verification_failed"
    let validFrames = generated.frames
    generated.frames = newSeq[Frame](28801)
    for frame in generated.frames.mitems: frame = validFrames[0]
    saveRecording(replayPath, generated)
    refusedOpen("verification_failed")
    generated.frames = validFrames
    saveRecording(replayPath, generated)

    # Extra frames after terminal must refuse, never stall indexing.
    generated.frames.add generated.frames[^1]
    saveRecording(replayPath, generated)
    refusedOpen("verification_failed")
    discard generated.frames.pop()
    saveRecording(replayPath, generated)

    # FFA is a distinct replay format, not a two-side inspection session.
    gameMode = gmFfaKin
    discard newWorld(generated.seed, generated.endTick)
    saveRecording(replayPath, generated)
    refusedOpen("unsupported")
    gameMode = gmTeams
    saveRecording(replayPath, generated)

    # Slice 7: the v1 seat schema must not authorize larger rosters.
    generated.seats = 18
    generated.names.setLen(18)
    for frame in generated.frames.mitems: frame.commands.setLen(18)
    saveRecording(replayPath, generated)
    refusedOpen("unsupported")
