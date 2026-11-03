## Read-only historical replay worker. One process owns one game's globals.
{.define: replayDebuggerStrict.}
import std/[json, os, strutils, parsejson, streams, sets, unicode, algorithm]

proc sha256(data: pointer, size: csize_t, output: pointer): pointer
  {.importc: "SHA256", dynlib: "libcrypto.so(|.3|.1.1)".}
proc digest(data: string): string =
  var bytes: array[32, uint8]
  discard sha256(data.cstring, data.len.csize_t, addr bytes[0])
  for b in bytes: result.add toHex(b, 2).toLowerAscii()
import game, sim, analysis, seat_view, kinship

const Protocol = "paintbot_replay_debugger_v1"
var
  opened: bool
  everOpened: bool
  stagedPath: string
  binding: JsonNode
  replayIndex: ReplayIndex

proc configureReplayDebugger*(path: string, engine: JsonNode) =
  ## Trusted embedding seam, never populated from request JSON.
  stagedPath = path
  binding = engine
  opened = false
  everOpened = false

proc session(visibility = "seat"): JsonNode =
  %*{"session_id": getEnv("PW_DEBUG_SESSION_ID"), "backend": "replay",
    "engine": binding, "tick": world.tick, "phase": "historical",
    "capabilities": ["replay_inspect"], "visibility": visibility,
    "verification": "verified", "terminal": world.winner != -1}

proc keys(n: JsonNode, names: openArray[string]): bool =
  if n.kind != JObject or n.len != names.len: return false
  for name in names:
    if not n.hasKey(name): return false
  true

proc validId(n: JsonNode): bool =
  if n.kind != JString: return false
  let s = n.getStr()
  if s.len notin 1..96 or s[0] notin {'a'..'z'}: return false
  for c in s:
    if c notin {'a'..'z', '0'..'9', '_', '-'}: return false
  true

proc debuggerEvents*(index: ReplayIndex): JsonNode =
  ## Pure projection of the existing verified replay analysis index.
  result = newJArray()
  template add(t, seat: int, kind, classification: string) =
    result.add %*{"tick": t, "seat": (if seat < 0: newJNull() else: %seat),
      "event_type": kind, "classification": classification, "evidence": []}
  for hit in index.hits: add(hit.tick-1, hit.slot, "hit", "observed")
  for event in index.events:
    if event.kind == "down": add(event.tick-1, event.slot, "down", "observed")
    elif event.kind in ["grenade pickup", "spray pickup", "shield pickup", "spray"]:
      add(event.tick-1, event.slot, "equipment_net_increase", "inferred")
  for tenures in index.heartTenures:
    for i in 1..<tenures.len:
      add(tenures[i].tick.int-1, -1, "heart_owner_change", "inferred")
  for tick in 0..<max(0, index.combat.len-1):
    for seat in 0..<index.combat[tick].len:
      for shot in 0..<(index.combat[tick+1][seat].shots - index.combat[tick][seat].shots):
        add(tick, seat, "shot", "observed")
  result.elems.sort(proc(a, b: JsonNode): int = cmp(a["tick"].getInt(), b["tick"].getInt()))

proc handleRequest*(req: JsonNode): JsonNode =
  if not req.keys(["schema_version", "operation_id", "method", "params"]) or
      not validId(req["operation_id"]) or req["method"].kind != JString:
    return %*{"schema_version": Protocol, "operation_id": "invalid_request", "method": "open",
      "status": "error", "data": nil, "provenance": [], "evidence_refs": [],
      "faults": [{"code": "invalid", "message": "Invalid request", "alternative": nil}],
      "publication_authorized": false}
  result = %*{"schema_version": Protocol, "operation_id": req["operation_id"],
    "method": req["method"], "status": "ok", "data": nil,
    "provenance": [], "evidence_refs": [], "faults": [],
    "publication_authorized": false}
  template fail(code: string) =
    result["status"] = %"error"
    result["faults"] = %*[{"code": code, "message": "Request refused", "alternative": nil}]
    return
  let p = req["params"]
  if not req.keys(["schema_version", "operation_id", "method", "params"]) or
      req["schema_version"] != %Protocol: fail("invalid")
  case req["method"].getStr()
  of "open":
    if not p.keys(["artifact_sha256", "engine"]): fail("invalid")
    if p["artifact_sha256"].kind != JString or p["artifact_sha256"].getStr().len != 64: fail("invalid")
    for c in p["artifact_sha256"].getStr():
      if c notin {'0'..'9', 'a'..'f'}: fail("invalid")
  of "seek":
    if not p.keys(["tick"]): fail("invalid")
  of "close":
    if not p.keys([]): fail("invalid")
  of "inspect":
    if not p.keys(["session_id", "seat", "entity_id", "lens", "fields"]): fail("invalid")
    if p["session_id"] != %getEnv("PW_DEBUG_SESSION_ID"): fail("unauthorized")
    if p["lens"] notin [%"seat", %"omniscient"]: fail("invalid")
    if p["lens"] == %"omniscient" and getEnv("PW_DEBUG_ALLOW_OMNISCIENT") != "1": fail("unauthorized")
    if p["seat"].kind == JNull:
      if p["lens"] != %"omniscient": fail("invalid")
    elif p["seat"].kind != JInt or p["seat"].getInt() notin 0..<Seats: fail("invalid")
    if p["entity_id"].kind != JNull and
        (p["entity_id"].kind != JInt or p["entity_id"].getInt() notin 0..<Seats): fail("invalid")
    if p["fields"].kind != JArray or p["fields"].len notin 1..10: fail("invalid")
    for field in p["fields"]:
      if field.kind != JString or field.getStr() notin ["tick", "terminal", "world_hash",
          "scores", "position", "hp", "team", "visible", "observation", "variables"]: fail("invalid")
  of "events":
    if not p.keys(["session_id", "start_tick", "end_tick", "event_types", "cursor", "limit"]): fail("invalid")
    if p["session_id"] != %getEnv("PW_DEBUG_SESSION_ID") or getEnv("PW_DEBUG_ALLOW_OMNISCIENT") != "1": fail("unauthorized")
    for key in ["start_tick", "end_tick"]:
      if p[key].kind != JInt or p[key].getInt() notin 0..28800: fail("invalid")
    if p["start_tick"].getInt() > p["end_tick"].getInt() or p["end_tick"].getInt() > recording.frames.len: fail("invalid")
    if p["limit"].kind != JInt or p["limit"].getInt() notin 1..256: fail("invalid")
    if p["cursor"].kind != JNull and (p["cursor"].kind != JString or p["cursor"].getStr().len > 256): fail("invalid")
    if p["event_types"].kind != JArray or p["event_types"].len notin 1..5: fail("invalid")
    for kind in p["event_types"]:
      if kind notin [%"hit", %"down", %"shot", %"heart_owner_change", %"equipment_net_increase"]: fail("invalid")
  else: fail("unsupported")
  if req["method"].getStr() notin ["open", "close"] and not opened: fail("conflict")
  case req["method"].getStr()
  of "open":
    if everOpened: fail("conflict")
    opened = false
    try:
      if getFileSize(stagedPath) > 67108864: fail("resource_limit")
      if p["engine"] != binding or digest(readFile(stagedPath)) != p["artifact_sha256"].getStr():
        raise newException(ValueError, "Binding mismatch")
      try:
        recording = loadRecording(stagedPath)
      except IndexDefect, RangeDefect:
        # Flatty reports truncated scalar payloads as bounds defects.
        raise newException(ValueError, "Malformed replay payload")
      if recording.endTick > 28800 or recording.frames.len > 28800: fail("resource_limit")
      if Seats > 16 or gameMode != gmTeams: fail("unsupported")
      if binding == nil or binding.kind != JObject or
          not binding.hasKey("rules_version") or not binding.hasKey("replay_version") or
          binding["rules_version"].kind != JInt or binding["replay_version"].kind != JInt:
        raise newException(ValueError, "Invalid version binding")
      if binding["rules_version"].getInt() != replayRulesVersion or
          binding["replay_version"].getInt() != replayGameVersion().int:
        raise newException(ValueError, "Version mismatch")
      replayMode = true
      replayIndex = indexReplay()
      replayIndex.restore(recording.frames.len)
      if world.winner == -1: raise newException(ValueError, "Incomplete replay")
      replayIndex.restore(0)
      opened = true
      everOpened = true
      result["data"] = session()
    except CatchableError:
      result["status"] = %"error"
      result["faults"] = %*[{"code": "verification_failed",
        "message": "Replay verification failed", "alternative": nil}]
  of "close":
    opened = false
    result["data"] = %*{"session_id": getEnv("PW_DEBUG_SESSION_ID"), "closed": true}
  of "seek":
    if p["tick"].kind != JInt or p["tick"].getInt() notin 0..recording.frames.len: fail("invalid")
    replayIndex.restore(p["tick"].getInt())
    result["data"] = session()
  of "events":
    var rows = newJArray()
    for event in debuggerEvents(replayIndex):
      if event["tick"].getInt() >= p["start_tick"].getInt() and event["tick"].getInt() <= p["end_tick"].getInt() and event["event_type"] in p["event_types"].elems:
        rows.add event
    let filter = digest($(%*[p["session_id"], p["start_tick"], p["end_tick"], p["event_types"], p["limit"]]))
    var offset = 0
    if p["cursor"].kind != JNull:
      let parts = p["cursor"].getStr().split(':')
      if parts.len != 2 or parts[0] != filter: fail("invalid")
      try: offset = parseInt(parts[1])
      except ValueError: fail("invalid")
      if offset < 0 or offset >= rows.len: fail("invalid")
    let stop = min(offset + p["limit"].getInt(), rows.len)
    var page = newJArray()
    for i in offset..<stop: page.add rows[i]
    result["data"] = %*{"session_id": p["session_id"], "events": page,
      "cursor": (if stop < rows.len: %(filter & ":" & $stop) else: newJNull())}
  of "inspect":
    beginViews(world)
    let entity = p["entity_id"].getInt(0)
    let row = seatView(p["seat"].getInt(0)).identityRow(entity)
    let omni = p["lens"] == %"omniscient"
    var values = newJArray()
    for field in p["fields"]:
      var value = newJNull()
      var missing = newJNull()
      case field.getStr()
      of "terminal": value = %(world.winner != -1)
      of "visible": value = %(omni or row.visible)
      of "team": value = %(if omni: team(entity) else: row.team)
      of "scores":
        let scores = world.scores()
        value = %*[{"side": 0, "value": scores[0]}, {"side": 1, "value": scores[1]}]
      of "observation", "variables": missing = %"not_captured"
      of "tick": value = %world.tick
      of "world_hash": value = %($world.stateHash())
      of "position":
        value = if omni: %*{"x": world.cogs[entity].pos.x, "z": world.cogs[entity].pos.z}
          else: %*{"x": row.x, "z": row.z}
      of "hp": value = %(if omni: world.cogs[entity].hp else: row.hp)
      else: discard
      if p["entity_id"].kind == JNull and field.getStr() notin ["tick", "terminal", "world_hash", "scores"]:
        value = newJNull()
        missing = %"not_applicable"
      elif not omni and not row.visible and field.getStr() in ["position", "hp", "team"]:
        value = newJNull()
        missing = %"not_visible"
      values.add %*{"field": field, "value": value, "missing_reason": missing}
    result["data"] = %*{"session": session(p["lens"].getStr()), "seat": p["seat"],
      "entity_id": p["entity_id"], "values": values}
  else: discard

proc validateValue(parser: var JsonParser, depth = 0) =
  if depth > 32: raise newException(ValueError, "Depth")
  case parser.kind
  of jsonObjectStart:
    var seen = initHashSet[string]()
    parser.next()
    while parser.kind != jsonObjectEnd:
      if parser.kind != jsonString or parser.str in seen:
        raise newException(ValueError, "Object key")
      seen.incl parser.str
      parser.next()
      validateValue(parser, depth+1)
    parser.next()
  of jsonArrayStart:
    parser.next()
    while parser.kind != jsonArrayEnd: validateValue(parser, depth+1)
    parser.next()
  of jsonFloat:
    let number = parseFloat(parser.str)
    if number != number or number == Inf or number == NegInf:
      raise newException(ValueError, "Nonfinite number")
    parser.next()
  of jsonString, jsonInt, jsonTrue, jsonFalse, jsonNull:
    parser.next()
  else: raise newException(ValueError, "JSON")

proc handleLine*(line: string): JsonNode =
  try:
    if line.len > 1048576 or validateUtf8(line) != -1 or line.startsWith("\xEF\xBB\xBF"):
      raise newException(ValueError, "Encoding or size")
    var parser: JsonParser
    parser.open(newStringStream(line), "request")
    defer: parser.close()
    parser.next()
    validateValue(parser)
    if parser.kind != jsonEof: raise newException(ValueError, "Trailing JSON")
    result = handleRequest(parseJson(line))
    if ($result).len > 1048576:
      opened = false
      result["status"] = %"error"
      result["data"] = newJNull()
      result["faults"] = %*[{"code": "resource_limit", "message": "Output limit exceeded", "alternative": nil}]
    return
  except CatchableError:
    return %*{"schema_version": Protocol, "operation_id": "invalid_request",
      "method": "open", "status": "error", "data": nil, "provenance": [],
      "evidence_refs": [], "faults": [{"code": "invalid", "message": "Invalid request",
      "alternative": nil}], "publication_authorized": false}

when isMainModule:
  try:
    configureReplayDebugger("/proc/self/fd/3", parseJson(getEnv("PW_DEBUG_ENGINE_BINDING")))
    var line = ""
    var oversized = false
    while not stdin.endOfFile:
      let c = stdin.readChar()
      if c == '\n':
        echo $handleLine(if oversized: "" else: line)
        stdout.flushFile()
        line.setLen(0)
        oversized = false
      elif line.len < 1048576: line.add c
      else: oversized = true
    if line.len > 0 or oversized:
      echo $handleLine("")
  except CatchableError:
    quit(2)
