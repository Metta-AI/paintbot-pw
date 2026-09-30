import
  std/[algorithm, httpclient, json, os, strutils, tables, times, uri],
  jsony, yaml/tojson,
  tournaments

type
  Softmax* = object
    http*: HttpClient
    server*: string
    token: string

proc tokenFromCredentials*(credentials: JsonNode, server: string): string =
  ## Prefers account access so roster discovery can see other players.
  result = credentials{"tokens", server}.getStr
  if result.len > 0:
    return
  let
    sessions = credentials{"player_sessions", server}
    active = sessions{"active"}.getStr
  if active.len > 0:
    let cached = sessions{"cache", active}
    if cached != nil:
      var expiry = cached{"expires_at"}.getStr
      let fraction = expiry.find('.')
      if fraction >= 0:
        var last = fraction + 1
        while last < expiry.len and expiry[last] in Digits:
          inc last
        expiry.delete(fraction ..< last)
      try:
        if parseTime(expiry, "yyyy-MM-dd'T'HH:mm:sszzz", utc()) > getTime():
          return cached{"token"}.getStr
      except TimeParseError:
        raise newException(TournamentError, "Invalid Softmax session expiry")
  result = credentials{"tokens", server}.getStr
  require(result.len > 0, "No Softmax login for " & server &
    ". Authenticate with softmax login first.")

proc connect*(server: string): Softmax =
  ## Opens Nim HTTP transport using the existing Softmax credentials file.
  let path = getHomeDir() / ".softmax/credentials.yaml"
  require(fileExists(path), "Authenticate with softmax login first")
  var documents: seq[JsonNode]
  try:
    documents = loadToJson(readFile(path))
  except CatchableError:
    raise newException(TournamentError, "Cannot parse Softmax credentials")
  require(documents.len == 1, "Expected one Softmax credentials document")
  result.server = server.strip(leading = false, chars = {'/'})
  result.token = tokenFromCredentials(documents[0], result.server)
  result.http = newHttpClient(timeout = 60000)

proc close*(client: Softmax) =
  ## Releases local HTTP resources without cancelling submitted games.
  client.http.close()

proc response(client: Softmax, verb, path: string,
    body: JsonNode): Response =
  ## Sends authenticated API calls while keeping credentials out of records.
  let headers = newHttpHeaders({"Authorization": "Bearer " & client.token,
    "Content-Type": "application/json"})
  let url = client.server & "/observatory" & path
  try:
    case verb
    of "GET":
      result = client.http.request(url, httpMethod = HttpGet, headers = headers)
    of "POST":
      result = client.http.request(url, httpMethod = HttpPost,
        headers = headers, body = body.toJson)
    else:
      raise newException(TournamentError, "Unsupported HTTP method: " & verb)
  except CatchableError as error:
    raise newException(
      TournamentError,
      "Softmax transport failed: " & error.msg
    )
  require(result.code.int in 200 .. 299,
    "Softmax " & verb & " " & path &
    " returned HTTP " & $result.code & ": " & result.body[0 ..< min(600,
      result.body.len)])

proc request*(client: Softmax, verb, path: string,
    body: JsonNode = nil): JsonNode =
  ## Reads API JSON, including original result artifacts without aggregation.
  tournaments.parseJson(client.response(verb, path, body).body)

proc transport*(client: Softmax): Client =
  ## Exposes the HTTP boundary used by the explicit tournament state loop.
  result.request = proc(verb, path: string, body: JsonNode): JsonNode =
    ## Preserves the saved request payload exactly on every retry.
    client.request(verb, path, body)

proc entries(client: Softmax, path: string): seq[JsonNode] =
  ## Exhausts a cursor-paginated API listing without dropping later entrants.
  var cursor = ""
  while true:
    let
      suffix = if cursor.len > 0: "&cursor=" & encodeUrl(cursor) else: ""
      reply = client.response("GET", path & suffix, nil)
      page = tournaments.parseJson(reply.body)
    if page.kind == JArray:
      result.add(page.elems)
      cursor = reply.headers.getOrDefault("X-Next-Cursor")
    else:
      require(page{"entries"} != nil, "Invalid Softmax listing: " & path)
      result.add(page["entries"].elems)
      cursor = page{"next_cursor"}.getStr
    if cursor.len == 0:
      break

proc snapshot*(client: Softmax, settings: JsonNode): JsonNode =
  ## Freezes the active ranked roster and the league's exact game release.
  var division: JsonNode
  if settings["division"].kind != JNull:
    division = client.request("GET", "/v2/divisions/" &
      settings["division"].getStr)
  else:
    for candidate in client.request("GET", "/v2/divisions?league_id=" &
        encodeUrl(settings["league"].getStr)):
      if candidate["name"].getStr == "Competition" and
        candidate{"archived_at"}.getStr.len == 0:
          require(
            division == nil,
            "Select one Competition division with --division"
          )
          division = candidate
  require(division != nil, "No active Competition division found")
  require(division["league"]["id"] == settings["league"],
    "Division does not belong to the selected league")
  let
    league = division["league"]
    divisionId = division["id"].getStr
  var members: Table[string, JsonNode]
  for member in client.entries("/v2/league-policy-memberships?division_id=" &
      encodeUrl(divisionId) &
      "&active_only=true&champions_only=true&limit=100"):
    if member{"player"} == nil or member["player"].kind == JNull:
      continue
    let player = member["player"]["id"].getStr
    if not members.hasKey(player) or member["created_at"].getStr >
      members[player]["created_at"].getStr:
        members[player] = member
  let roster = newJArray()
  var leaderboard = client.request("GET", "/v2/divisions/" &
    divisionId & "/leaderboard").getElems
  leaderboard.sort(proc(a, b: JsonNode): int =
    ## Keeps selection deterministic when leaderboard ranks are equal.
    result = cmp(a["rank"].kind == JNull, b["rank"].kind == JNull)
    if result == 0:
      result = cmp(a["rank"].getInt, b["rank"].getInt)
    if result == 0:
      result = cmp(a["player_id"].getStr, b["player_id"].getStr))
  var seen: Table[string, bool]
  for row in leaderboard:
    let player = row["player_id"].getStr
    if not members.hasKey(player) or row["rank"].kind == JNull:
      continue
    let
      policy = members[player]["policy_version"]
      id = policy["id"].getStr
      policyName = policy["policy"]["name"].getStr
    if seen.hasKey(id) or
      %id in league["filler_policy_version_ids"].getElems:
        continue
    seen[id] = true
    roster.add %*{"id": id, "player_id": player,
      "name": row{"player_name"}.getStr(policyName),
      "version": policyName & ":v" & $policy["version"].getInt,
      "league_rank": row["rank"]}
    if roster.len == settings["top"].getInt:
      break
  require(roster.len == settings["top"].getInt,
    "Not enough eligible policies: " & $roster.len)
  let
    worldId = league["game"]{"canonical_coworld_id"}.getStr
  require(worldId.len > 0, "League has no canonical game release")
  let world = client.request(
    "GET",
    "/v2/coworlds/" & encodeUrl(worldId)
  )
  let manifest = world["manifest"]
  var config: JsonNode
  for variant in manifest["variants"]:
    if variant["id"].getStr == "competition":
      config = variant["game_config"].copy()
  require(config != nil, "The release needs a competition variant")
  if config.hasKey("tokens"):
    config.delete("tokens")
  require(config["players"].len == Seats,
    "Paintbot Competition must have sixteen seats")
  require(config{"mode"}.getStr in ["", "teams"],
    "Tournament requires Paintbot teams, not Heartland")
  result = %*{"league_snapshot": league, "roster": roster, "game_config": config,
    "release": {"id": world["id"], "version": world["version"],
      "variant": "competition", "league": league["id"],
      "division": divisionId, "manifest_hash": world["manifest_hash"]}}
