import std/[json, os, sequtils, strutils]
import tournaments, reports

proc execute*(client: Client, directory: string, run: JsonNode,
    dataRoot: string, controls: Controls): int =
  ## Reconciles saved requests before scheduling any new tournament games.
  require(controls.concurrency > 0, "Concurrency must be positive")
  var records = loadRecords(directory, run)
  try:
    if controls.retryFailed:
      for record in records:
        if record["state"].getStr == "failed":
          record["state"] = %"planned"
          if record.hasKey("error"):
            record.delete("error")
          saveRecord(directory, record, controls)
    publish(directory, run, records, "running", dataRoot, controls = controls)
    while not stopping:
      records = loadRecords(directory, run)
      for i, game in run["schedule"].elems:
        if stopping:
          break
        let record = records[i]
        if record["state"].getStr in ["planned", "completed", "failed"]:
          continue
        let attempt = record["attempts"][record["attempts"].len - 1]
        let detail = if attempt.hasKey("request_id"):
          client.request("GET", "/v2/experience-requests/" &
            attempt["request_id"].getStr, nil)
          else:
            recoverRequest(client, attempt)
        receive(client, directory, run, game, record, detail, controls)
        publish(
          directory,
          run,
          records,
          "running",
          dataRoot,
          controls = controls
        )
      if stopping:
        break
      if records.anyIt(it["state"].getStr == "failed"):
        publish(directory, run, records, "failed", dataRoot,
          "A game failed. Inspect its details, then use --retry-failed.",
          controls)
        return 1
      if records.allIt(it["state"].getStr == "completed"):
        publish(directory, run, records, "completed", dataRoot,
          controls = controls)
        return 0
      var active = records.countIt(it["state"].getStr notin
        ["planned", "completed", "failed"])
      for i, game in run["schedule"].elems:
        if stopping or active >= controls.concurrency:
          break
        let record = records[i]
        if record["state"].getStr != "planned":
          continue
        let attempt = %*{"body": requestBody(run, game,
          record["attempts"].len + 1), "created": now()}
        record["attempts"].add(attempt)
        record["state"] = %"submitting"
        saveRecord(directory, record, controls)
        if controls.fault != nil:
          controls.fault("submission-intent")
        if stopping:
          attempt["status"] = %"not_sent"
          record["state"] = %"planned"
          saveRecord(directory, record, controls)
          break
        let detail = client.request("POST", "/v2/experience-requests",
          attempt["body"])
        if controls.fault != nil:
          controls.fault("remote-acceptance")
        receive(client, directory, run, game, record, detail, controls)
        publish(
          directory,
          run,
          records,
          "running",
          dataRoot,
          controls = controls
        )
        if record["state"].getStr == "failed":
          break
        if record["state"].getStr != "completed":
          inc active
      var elapsed = 0
      while not stopping and elapsed < controls.pollMilliseconds:
        let delay = min(100, controls.pollMilliseconds - elapsed)
        sleep(delay)
        elapsed += delay
    publish(directory, run, loadRecords(directory, run), "paused", dataRoot,
      controls = controls)
    result = 130
  except CatchableError as error:
    publish(directory, run, loadRecords(directory, run), "paused", dataRoot,
      error.msg, controls)
    raise

proc parseArguments*(arguments: seq[string]): JsonNode =
  ## Distinguishes explicit frozen settings from operational resume options.
  result = %*{"run": "", "concurrency": 4, "retry_failed": false,
    "report_only": false, "no_site": false,
    "help": false, "settings": {}}
  var i = 0
  while i < arguments.len:
    let parts = arguments[i].split('=', maxsplit = 1)
    let name = parts[0]
    if name in ["--help", "-h"]:
      result["help"] = %true
    elif name in ["--retry-failed", "--report-only", "--no-site"]:
      require(parts.len == 1, name & " does not take a value")
      result[name[2 .. ^1].replace('-', '_')] = %true
    else:
      require(name in ["--run", "--games", "--top", "--format", "--seed",
        "--check-every", "--league", "--division", "--concurrency",
        "--server", "--site"], "Unknown option: " & name)
      var value: string
      if parts.len == 2:
        value = parts[1]
      else:
        inc i
        require(i < arguments.len, "Missing value for " & name)
        value = arguments[i]
      require(value.len > 0, "Missing value for " & name)
      let field = name[2 .. ^1].replace('-', '_')
      var parsed = %value
      if field in ["games", "top", "seed", "check_every", "concurrency"]:
        try:
          parsed = %parseInt(value)
        except ValueError:
          raise newException(TournamentError, name & " requires an integer")
        if field != "seed":
          require(parsed.getInt > 0, name & " must be positive")
        if field == "top":
          require(parsed.getInt <= 100, "--top cannot exceed 100")
      if field in ["run", "server", "concurrency", "site"]:
        result[field] = parsed
      else:
        result["settings"][field] = parsed
    inc i
  if result["help"].getBool:
    return
  require(not (result["no_site"].getBool and result.hasKey("site")),
    "Use either --site or --no-site")
  let name = result["run"].getStr
  require(name.len in 1 .. 80 and name[0] in Letters + Digits,
    "--run requires a name beginning with a letter or digit")
  require(name.allCharsInSet(Letters + Digits + {'_', '-', '.'}),
    "Run names may contain only letters, digits, dots, underscores and dashes")
  if result["settings"].hasKey("format"):
    require(result["settings"]["format"].getStr in ["mixed", "mono", "both"],
      "--format must be mixed, mono, or both")

proc validateResume*(run, arguments: JsonNode) =
  ## Rejects explicitly conflicting settings while allowing new concurrency.
  require(run{"schema"}.getInt == Schema, "Unsupported saved run schema")
  for name, value in arguments["settings"]:
    require(run["settings"]{name} == value,
      "Cannot change --" & name.replace('_', '-') & " on resume")
  if arguments.hasKey("server"):
    require(run["server"] == arguments["server"],
      "Cannot change --server on resume")
