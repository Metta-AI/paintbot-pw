## The Coworld game config's match keys, parsed once for the hosted game (game.nim's
## applyGameConfig and setup) and the training library (native_env's pw_set_config_json), so
## the two can never read a config differently.
import std/[json, options]
import sim, kinship

const
  GloryAwardLimit* = 1000 ## the most one glory award may pay
  GloryPeriodLimit* = 600 ## the longest glory period, in seconds
  GloryConfigKeys = ["quiet_supplies", "quiet_supplies_seconds", "behind_lives",
    "behind_lives_seconds", "heart", "behind_cogs", "behind_cogs_seconds"]
proc validGloryConfig*(g: GloryConfig): bool =
  g.quietSupplies in 0..GloryAwardLimit and g.behindLives in 0..GloryAwardLimit and
    g.heart in 0..GloryAwardLimit and g.behindCogs in 0..GloryAwardLimit and
    g.quietSupplySeconds in 1..GloryPeriodLimit and g.behindLivesSeconds in 1..GloryPeriodLimit and
    g.behindCogsSeconds in 1..GloryPeriodLimit
proc parseGloryConfig*(node: JsonNode): GloryConfig =
  ## The Coworld config's optional "glory" object (rules 43, teams game). Each key overrides
  ## one default award; absent keys keep the default. Keys: quiet_supplies (glory per quiet
  ## stretch), quiet_supplies_seconds (its length), behind_lives (glory per life behind),
  ## behind_lives_seconds (its period), heart (a glory heart's award), and from rules 47
  ## behind_cogs (glory per cog out of the match beyond the enemy's) and behind_cogs_seconds.
  result = DefaultGloryConfig
  if node.isNil or node.kind == JNull: return
  if node.kind != JObject: raise newException(ValueError, "Paintbot glory must be an object")
  for key, value in node.pairs:
    if key notin GloryConfigKeys: raise newException(ValueError, "Unknown Paintbot glory key: " & key)
    if value.kind != JInt: raise newException(ValueError, "Paintbot glory " & key & " must be an integer")
    let n = value.getBiggestInt
    if n notin 0'i64..int64(GloryAwardLimit+GloryPeriodLimit):
      raise newException(ValueError, "Paintbot glory " & key & " is out of range")
    case key
    of "quiet_supplies": result.quietSupplies = n.int32
    of "quiet_supplies_seconds": result.quietSupplySeconds = n.int32
    of "behind_lives": result.behindLives = n.int32
    of "behind_lives_seconds": result.behindLivesSeconds = n.int32
    of "heart": result.heart = n.int32
    of "behind_cogs": result.behindCogs = n.int32
    of "behind_cogs_seconds": result.behindCogsSeconds = n.int32
  if not validGloryConfig(result):
    raise newException(ValueError, "Paintbot glory awards must be 0.." & $GloryAwardLimit &
      " and periods 1.." & $GloryPeriodLimit & " seconds")
proc parseGameMode*(config: JsonNode): GameMode =
  ## The coworld config's optional "mode": absent or "teams" is the two-team game.
  let mode = config{"mode"}
  if mode.isNil or mode.kind == JNull: return gmTeams
  if mode.kind != JString: raise newException(ValueError, "Paintbot mode must be a string")
  case mode.getStr
  of "teams": gmTeams
  of "ffa_kin": gmFfaKin
  else: raise newException(ValueError, "Unknown Paintbot mode: " & mode.getStr)
proc parseKinLayout*(config: JsonNode, mode: GameMode): Option[KinLayout] =
  ## The coworld config's optional "kin_layout": absent or "sampled" draws a layout per seed;
  ## a layout name pins every match to it. FFA-kin only: a teams config may not set it.
  let layout = config{"kin_layout"}
  if layout.isNil or layout.kind == JNull: return none(KinLayout)
  if layout.kind != JString: raise newException(ValueError, "Paintbot kin_layout must be a string")
  if mode != gmFfaKin:
    raise newException(ValueError, "Paintbot kin_layout requires \"mode\": \"ffa_kin\"")
  case layout.getStr
  of "sampled": none(KinLayout)
  of "fours": some(klFours)
  of "pairs": some(klPairs)
  of "trios_loner": some(klTriosLoner)
  of "cousins": some(klCousins)
  of "strangers": some(klStrangers)
  of "clones": some(klClones)
  of "tribes": some(klTribes)
  else: raise newException(ValueError, "Unknown Paintbot kin_layout: " & layout.getStr)

type MatchConfig* = object
  ## What a match plays, from the Coworld game config: the host reads each key here (mode,
  ## kin_layout, glory) or through CoworldConfig (map, vision); pw_set_config_json reads them all.
  mode*: GameMode
  kinLayout*: Option[KinLayout]
  glory*: GloryConfig
  map*: string   ## "" = Heartwick island, else a MapNames entry
  mapGiven*: bool ## the config names a map ("" included); the host plays Heartwick without one
  vision*: string ## "" = per-cog sight lines, "team" = one sight grid per team

const
  MatchConfigKeys* = ["mode", "kin_layout", "glory", "map", "vision"]
  ## The config schema's other keys (coworld_manifest_template.json config_schema): the host's
  ## seating and match length, which a training handle takes from its own calls.
  SeatingConfigKeys* = ["tokens", "players", "slots", "seed", "max_ticks"]

proc parseMatchConfig*(config: JsonNode): MatchConfig =
  ## A whole game config object, as a variant's game_config in the manifest: the checks and
  ## messages the host applies (applyGameConfig, setup), and no key the schema lacks.
  if config.isNil or config.kind != JObject: raise newException(ValueError, "Paintbot config must be an object")
  for key, value in config.pairs:
    if key notin MatchConfigKeys and key notin SeatingConfigKeys:
      raise newException(ValueError, "Unknown Paintbot config key: " & key)
  result.mode = parseGameMode(config)
  result.kinLayout = parseKinLayout(config, result.mode)
  let glory = config{"glory"}
  if not glory.isNil and glory.kind != JNull and result.mode == gmFfaKin:
    raise newException(ValueError, "Paintbot glory awards apply to the teams game only")
  result.glory = parseGloryConfig(glory)
  for key in ["map", "vision"]:
    let node = config{key}
    if node.isNil or node.kind == JNull: continue
    if node.kind != JString: raise newException(ValueError, "Paintbot " & key & " must be a string")
    if key == "map": (result.map = node.getStr; result.mapGiven = true) else: result.vision = node.getStr
  discard mapIndex(result.map) # raises for a name that is not a map, as configureMap does
  if result.vision notin ["", "team"]:
    raise newException(ValueError, "Unknown Paintbot vision mode: " & result.vision)
  if result.vision.len > 0 and result.mode == gmFfaKin:
    raise newException(ValueError, "Team vision applies to the teams game only")
