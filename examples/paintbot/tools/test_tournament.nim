import
  std/[json, os, osproc, posix, sequtils, sets, strutils, tables],
  tournaments, reports, runners, softmax, sites

const
  DataRoot = Root.parentDir / "polyworld_art"
  TestRoot = Root / "tmp/paintbot/tournament-tests"

proc fixture(count = 41, mode = "both", interval = 10): JsonNode =
  ## Builds a named fixture that never submits hosted games.
  result = %*{"schema": Schema, "id": "nim-fixture", "name": "nim-fixture",
    "created": "2026-09-14T00:00:00Z", "settings": defaults(),
    "server": "https://softmax.com/api", "web_url": "https://softmax.com",
    "release": {"id": "cow_fixture", "version": "test fixture",
      "variant": "competition"}, "game_config": {"max_ticks": 28800},
    "roster": [], "schedule": scheduleGames(count, 10, mode, 17)}
  result["settings"]["games"] = %count
  result["settings"]["format"] = %mode
  result["settings"]["check_every"] = %interval
  for policy in 0 ..< 10:
    result["roster"].add %*{"id": "policy-" & align($policy, 2, '0'),
      "name": "Fixture policy " & $(policy + 1),
      "version": "fixture:v" & $(policy + 1)}

proc resultFor(game: JsonNode, outcome = "0", ticks = 720): JsonNode =
  ## Produces seat-attributed tournament scores and explicit team outcomes.
  result = %*{"scores": [], "outcome": outcome, "ticks": ticks,
    "seed": game["seed"]}
  for slot in 0 ..< Seats:
    result["scores"].add %(if result.seatWin(slot) == 1: 400 else: 0)

proc completed(run: JsonNode): seq[JsonNode] =
  ## Creates one completed authoritative record per fixture game.
  for game in run["schedule"]:
    result.add %*{"id": game["id"], "state": "completed", "attempts": [],
      "result": resultFor(game)}

proc fresh(name: string): string =
  ## Resets only the bounded fixture output owned by this test suite.
  result = TestRoot / name
  if dirExists(result):
    removeDir(result)
  createDir(result)

proc fakeClient(directory: string, pauseAfterAccept = false): Client =
  ## Models durable remote requests that survive the local runner process.
  let path = directory / "remote.json"
  if not fileExists(path):
    saveJson(path, newJObject())
  result.request = proc(verb, route: string, body: JsonNode): JsonNode =
    ## Rejects repeated POSTs and lets accepted games complete while stopped.
    let requests = readJson(path)
    if verb == "POST":
      let key = body["idempotency_key"].getStr
      require(not requests.hasKey(key), "Duplicate POST for a saved attempt")
      if not requests.hasKey(key):
        let
          id = $requests.len
          policies = newJArray()
          fail = fileExists(directory / "fail-next")
        if fail:
          removeFile(directory / "fail-next")
        for seat in body["roster"]:
          policies.add(seat["player"]["policy_ref"])
        requests[key] = %*{"id": "xreq_" & id,
          "coworld_id": body["coworld_id"], "body": body,
          "requested": {"notes": body["notes"]},
          "episodes": [{"id": "ereq_" & id,
            "status": (if fail: "failed" else: "pending"),
            "game_config": body["game_config_overrides"],
            "policy_version_ids": policies}]}
        saveJson(path, requests)
      require(requests[key]["body"] == body, "Conflicting idempotency key")
      if pauseAfterAccept:
        writeFile(directory / "accepted", "yes")
        var waited = 0
        while not stopping and waited < 30000:
          sleep(10)
          waited += 10
      return requests[key].copy()
    if route.startsWith("/v2/experience-requests?"):
      let entries = newJArray()
      for key, request in requests:
        entries.add %*{"id": request["id"]}
      return %*{"entries": entries, "next_cursor": nil}
    for key, request in requests:
      let episode = request["episodes"][0]
      if route.endsWith("/" & request["id"].getStr):
        episode["status"] = %"completed"
        saveJson(path, requests)
        return request.copy()
      if route.contains("/" & episode["id"].getStr & "/artifacts/results"):
        let game = %*{"seed": request["body"]["game_config_overrides"]["seed"],
          "seats": []}
        for seat in request["body"]["roster"]:
          let id = seat["player"]["policy_ref"].getStr
          game["seats"].add %parseInt(id[7 .. ^1])
        return resultFor(game)
    raise newException(TournamentError, "Unknown fake request: " & route)

proc assertEquivalent(first, second: JsonNode) =
  ## Compares final values and checkpoint histories independently of timestamps.
  for field in ["target", "completed", "included", "panels", "roster"]:
    doAssert first[field] == second[field], "Mismatch in " & field

proc stop() {.noconv.} =
  ## Allows subprocess SIGINT tests to finish their in-flight response.
  stopping = true

if paramCount() > 0 and paramStr(1) == "worker":
  setControlCHook(stop)
  let
    directory = paramStr(2)
    run = readJson(directory / "run.json")
  quit(execute(fakeClient(directory, true), directory, run, DataRoot,
    Controls(concurrency: 2)))

createDir(TestRoot)
echo "Checking schedules, side assignments, and per-policy averages"
for mode in ["both", "mixed", "mono"]:
  let schedule = scheduleGames(101, 10, mode, 20260930)
  doAssert schedule == scheduleGames(101, 10, mode, 20260930)
  doAssert schedule.len == 101
  doAssert schedule.elems.mapIt(it["seed"].getInt).toHashSet.len == 101
  if mode == "both":
    doAssert schedule.elems.countIt(it["format"].getStr == "mixed") == 51
  var
    appearances: array[2, array[10, int]]
    sides: array[2, array[10, array[2, int]]]
    extras: array[10, int]
  for game in schedule:
    var teams: array[2, seq[int]]
    for slot, policy in game["seats"].elems:
      teams[slot mod 2].add(policy.getInt)
    let kind = if game["format"].getStr == "mixed": 0 else: 1
    doAssert (teams[0].toHashSet * teams[1].toHashSet).len == 0
    for side in 0 ..< 2:
      doAssert teams[side].len == TeamSize
      doAssert teams[side].toHashSet.len == (if kind == 0: 5 else: 1)
      for policy in teams[side].toHashSet:
        inc appearances[kind][policy]
        inc sides[kind][policy][side]
        if kind == 0:
          doAssert teams[side].count(policy) in 1 .. 2
          extras[policy] += teams[side].count(policy) - 1
    let values = gameValues(game, resultFor(game))
    doAssert values.len == (if kind == 0: 10 else: 2)
    for policy, value in values:
      doAssert value == (if policy in teams[0]: [1.0, 400.0]
        else: [0.0, 0.0])
  for kind in 0 ..< 2:
    doAssert max(appearances[kind]) - min(appearances[kind]) <= 1
    for policy in 0 ..< 10:
      doAssert abs(sides[kind][policy][0] - sides[kind][policy][1]) <= 3
  doAssert max(extras) - min(extras) <= 3

echo "Checking native score contracts and time-limit victories"
block:
  let
    run = fixture(1)
    game = run["schedule"][0]
  for outcome in ["0", "1", "time_limit"]:
    let raw = resultFor(game, outcome, 28800)
    validateResult(raw, game, run)
    for slot in 0 ..< Seats:
      doAssert raw.seatWin(slot) == ord(outcome == $(slot mod 2))
    raw["scores"] = %repeat(0, Seats)
    validateResult(raw, game, run)
    doAssert raw.seatWin(0) == ord(outcome == "0")
  for field in ["seed", "scores", "ticks", "outcome"]:
    let raw = resultFor(game)
    raw[field] = %"invalid"
    var rejected = false
    try:
      validateResult(raw, game, run)
    except TournamentError:
      rejected = true
    doAssert rejected
  let negative = resultFor(game)
  negative["scores"].elems[0] = %(-1)
  var rejected = false
  try:
    validateResult(negative, game, run)
  except TournamentError:
    rejected = true
  doAssert rejected

echo "Checking ties, partial batches, rank movement, and stability resets"
block:
  let run = fixture(41, "mixed")
  for game in run["schedule"]:
    game["seats"] = %toSeq(0 ..< Seats).mapIt(it mod 10)
  let records = completed(run)
  let summary = summarize(run, records, "completed")
  let panel = summary["panels"][1]
  doAssert panel["history"].len == 4
  doAssert panel["stability"]["score"].getInt == 0
  doAssert panel["stability"]["run"].getInt == 3
  doAssert panel["included"].getInt == 41
  doAssert panel["history"][0]["score"].kind == JNull
  var counts = repeat(1, 10)
  counts[9] = 0
  let rows = rankedRows(run, newSeq[Values](10), counts, 0)
  doAssert rows[0]["tied"].getBool
  doAssert rows[0]["id"].getStr == "policy-00"
  doAssert rows[9]["rank"].kind == JNull
  let changed = rows.copy()
  changed[0]["rank"] = %2
  changed[1]["rank"] = %1
  doAssert rankChanges(rows, changed) == 2
  records[5]["state"] = %"pending"
  let gap = summarize(run, records, "running")
  doAssert gap["completed"].getInt == 40
  doAssert gap["included"].getInt == 5
block:
  let run = fixture(4, "mono", 1)
  for game in run["schedule"]:
    game["seats"] = %toSeq(0 ..< Seats).mapIt(it mod 2)
  let records = completed(run)
  records[2]["result"] = resultFor(run["schedule"][2], "1")
  records[3]["result"] = resultFor(run["schedule"][3], "1")
  for slot in countup(1, Seats - 1, 2):
    records[2]["result"]["scores"].elems[slot] = %1000
    records[3]["result"]["scores"].elems[slot] = %1000
  let history = summarize(run, records, "completed")["panels"][3]["history"]
  doAssert history[1]["run"].getInt == 1
  doAssert history[2]["score"].getInt == 2
  doAssert history[2]["run"].getInt == 0
  doAssert history[3]["run"].getInt == 1
echo "Checking durable retries and interrupted atomic replacements"
let
  run = fixture(6, "both", 1)
  baselineDirectory = fresh("uninterrupted")
saveJson(baselineDirectory / "run.json", run)
doAssert execute(fakeClient(baselineDirectory), baselineDirectory, run,
  DataRoot, Controls(concurrency: 2)) == 0
let baseline = readJson(baselineDirectory / "summary.json")
for point in ["remote-acceptance", "result-received",
    "result-saved",
    "replace:000001.json", "replace:report.html"]:
  let directory = fresh(point.replace(':', '-'))
  saveJson(directory / "run.json", run)
  var fired = false
  let fault = proc(location: string) =
    ## Simulates abrupt failure at one precise persistence boundary.
    if point == "replace:report.html" and not loadRecords(directory,
      run).anyIt(it["state"].getStr == "completed"):
        return
    if not fired and location == point:
      fired = true
      raise newException(TournamentError, "Injected interruption")
  var failed = false
  try:
    discard execute(fakeClient(directory), directory, run, DataRoot,
      Controls(concurrency: 2, fault: fault))
  except TournamentError:
    failed = true
  doAssert failed and fired
  doAssert readJson(directory / "summary.json")["status"].getStr == "paused"
  doAssert execute(fakeClient(directory), directory, run, DataRoot,
    Controls(concurrency: 4)) == 0
  assertEquivalent(baseline, readJson(directory / "summary.json"))
  doAssert readJson(directory / "remote.json").len == 6

echo "Checking report escaping, assets, site placement, and frozen options"
block:
  let unsafe = run.copy()
  unsafe["roster"][0]["name"] = %"</script><img src=x onerror=alert(1)> & \""
  unsafe["roster"][0]["version"] = %"<unsafe>\"policy:v1"
  let
    summary = summarize(unsafe, completed(unsafe), "completed")
    html = render(summary, DataRoot)
    site = fresh("site")
  doAssert "</script><img src=x" notin html
  doAssert "&lt;/script&gt;&lt;img" in html
  doAssert "data:font/ttf;base64," in html
  doAssert "data:image/png;base64," in html
  doAssert "@@" notin html
  doAssert html.count("class=ladder-stability") == 4
  doAssert html.count("<article class=\"panel ladder\"") == 4
  doAssert "setInterval" notin html
  doAssert "Match history" notin html
  doAssert "Avg Glory" in html
  doAssert "text-overflow:ellipsis" in html
  doAssert "Streak:" in html and " player swaps" in html
  doAssert "data-status=\"completed\"" in html
  createDir(site / "Paintbot")
  writeFile(site / "Paintbot/index.html",
    "<a class=\"jump\" href=\"#overview\">Learn the game &darr;</a>")
  updateSite(html, summary, DataRoot, site)
  let page = readFile(site / "Paintbot/standings/index.html")
  doAssert "data:image/" notin page
  doAssert "../assets/icons/victory.png" in page
  doAssert "href=\"standings/\"" in readFile(site / "Paintbot/index.html")
  doAssert page == readFile(site / "Paintbot/standings/nim-fixture.html")
  updateSite(html, summary, DataRoot, site)
  doAssert readFile(site / "Paintbot/index.html").count("standings/") == 1
  validateResume(run, parseArguments(@["--run", "test", "--concurrency", "8"]))
  var rejected = false
  try:
    validateResume(run, parseArguments(@["--run", "test", "--games", "12"]))
  except TournamentError:
    rejected = true
  doAssert rejected
  let credentials = %*{"tokens": {"test": "account"},
    "player_sessions": {"test": {"active": "player"}}}
  doAssert tokenFromCredentials(credentials, "test") == "account"
block:
  let directory = fresh("unconfirmed-submission")
  saveJson(directory / "run.json", run)
  let record = loadRecords(directory, run)[0]
  record["state"] = %"submitting"
  record["attempts"].add %*{"body": requestBody(run, run["schedule"][0], 1)}
  saveRecord(directory, record)
  var unresolved = false
  try:
    discard execute(fakeClient(directory), directory, run, DataRoot,
      Controls(concurrency: 4))
  except TournamentError:
    unresolved = true
  doAssert unresolved
  doAssert readJson(directory / "remote.json").len == 0
  doAssert readJson(directory / "games/000001.json")["state"].getStr ==
    "submitting"
  discard fakeClient(directory).request("POST", "/v2/experience-requests",
    record["attempts"][0]["body"])
  doAssert execute(fakeClient(directory), directory, run, DataRoot,
    Controls(concurrency: 4)) == 0
  doAssert readJson(directory / "remote.json").len == 6
block:
  let directory = fresh("atomic")
  let path = directory / "state.json"
  saveJson(path, %*{"old": true})
  try:
    saveJson(path, %*{"new": true}, Controls(fault: proc(point: string) =
      ## Interrupts after the temporary file is durable.
      raise newException(TournamentError, "Injected replacement failure")))
  except TournamentError:
    discard
  doAssert readJson(path) == %*{"old": true}
  doAssert fileExists(path & ".tmp")
block:
  let directory = fresh("failed-retry")
  saveJson(directory / "run.json", run)
  writeFile(directory / "fail-next", "yes")
  doAssert execute(fakeClient(directory), directory, run, DataRoot,
    Controls(concurrency: 2)) == 1
  doAssert readJson(directory / "summary.json")["failed"].getInt == 1
  doAssert execute(fakeClient(directory), directory, run, DataRoot,
    Controls(concurrency: 2, retryFailed: true)) == 0
  doAssert readJson(directory / "remote.json").len == 7
  doAssert readJson(directory / "games/000001.json")["attempts"].len == 2
  assertEquivalent(baseline, readJson(directory / "summary.json"))

echo "Checking real SIGINT and SIGKILL recovery after remote acceptance"
for signal in [SIGINT, SIGKILL]:
  let directory = fresh("signal-" & $signal)
  saveJson(directory / "run.json", run)
  let worker = startProcess(getAppFilename(), args = @["worker", directory],
    options = {poParentStreams})
  var waited = 0
  while not fileExists(directory / "accepted") and waited < 10000:
    doAssert worker.running()
    sleep(20)
    waited += 20
  doAssert fileExists(directory / "accepted")
  doAssert posix.kill(worker.processID.cint, signal) == 0
  discard worker.waitForExit(10000)
  doAssert not worker.running()
  worker.close()
  if signal == SIGINT:
    doAssert readJson(directory / "summary.json")["status"].getStr == "paused"
  doAssert execute(fakeClient(directory), directory, run, DataRoot,
    Controls(concurrency: 4)) == 0
  doAssert readJson(directory / "remote.json").len == 6
  assertEquivalent(baseline, readJson(directory / "summary.json"))
