# Paintbot PW

Sixteen wheeled cogs fight for territory in Heartwick. Red uses even slots;
Blue uses odd slots. Ten stationary hearts divide the entire map into nearest-heart
regions. Each team starts with its base heart; eight hearts start neutral gray.
Stay within 140 units of a heart on connected terrain for three seconds (72 ticks)
to claim it. Extra cogs do not accelerate capture. Both teams in range pause
progress; if the attackers leave or only defenders remain, progress resets.
The current owner keeps earning points until capture completes. Holding all ten increases income but does not immediately end the game.

The default-on territory overlay colors each region by its heart owner, including
neutral gray. Toggle it off for an unobstructed terrain view. Heart locations and
ownership are public. BASIC exposes `heartCount()`, `controlX(i)`, `controlY(i)`,
and `controlOwner(i)` (-1 neutral, 0 red, 1 blue). Capture state is also public:
`controlCaptureTeam(i)` (-1 idle), `controlCaptureTicks(i)` (0–71 of 72), and
`controlContested(i)` (0 or 1). Invalid indices return -1. Glory is
public too: `glory(team)` (-1 for an invalid team) (rules 37).

Cogs have three base HP and three respawns (four lives total). Death loses equipment and respawns
after 72 ticks; spawn protection lasts 36 ticks. Initial spawns and respawns are within 350 world units
of an owned heart, sampled with softmax over the sum of distances from living teammates (excluding
self). Larger sums favor less-covered hearts. Temperature is 1,000 world units, with distances
quantized to 10 units for deterministic sampling. With no owned hearts, respawns use the endzone.
Blocked or crowded heart placements retry on the next tick. Each owned normal heart earns its team one point per second, accumulated at 24 ticks
per second. Each team's heart meter holds 900 points: five of the ten hearts held
for 180 seconds fills it exactly. Every heart has equal income. The first team to
fill its meter wins. Typical matches target about five minutes including capture
and contest time; the hard limit is ten minutes (14,400 ticks). At the limit, the
higher meter wins; equal totals draw. Simultaneous fills use the higher point total,
with equal totals drawing. A team is eliminated when every cog is out with no
respawns left; it loses immediately and the surviving team's meter fills (rules 34).
If both teams are eliminated on the same tick, the match ends with no bonus and the
higher meter wins; equal totals draw. There is no bombardment or overtime.
The match score is **glory** (rules 37), a self-imposed handicap. Each team starts with the
match length in seconds (600) and loses one glory per second. Every thirty seconds without
collecting a supply adds 10, and friendly fire taken in the opening thirty seconds 30 per
hit; nothing that makes a team more likely to win pays glory. When the match ends the loser's glory drops to zero
and a draw pays nobody; the winner's glory is its score and the ladder input. The heart
meter still decides who wins. See "Glory" below.
Older replays retain their original capture-the-heart rules.

## Combat and equipment

- Solid bodies block teammates and opponents. Movement while carrying is 70%.
- Vision is a 120-degree forward cone with unlimited distance and wall occlusion.
- Paintball guns lock aim during a five-tick windup, then trace a hitscan ray.
  Friendly fire is enabled. Shots released together choose targets before damage.
  Range is 5250 units. The user-selected cadence is one shot per second.
- Four grenade pickups refill after five seconds. Carry one; hold C to charge up
  to 24 ticks and release to throw. Grenades fly over walls, land after ten ticks,
  and deal two damage to every body in the blast, including allies and yourself.
- Spray cans refill after 30 seconds. A carried can replaces the gun. Fire sends
  a directional cone for five ticks, with 20 ticks of recovery. Aim locks at the
  beginning of each burst; each victim takes three damage once per burst.
- Trenches are walkable pits. Entering is full speed; movement outward is slowed
  fivefold. Gun cooldown is tripled, and 70% of outside gunfire passes overhead.
  Shots from inside the same trench and spray ignore that protection. Grenades
  deal six damage to victims in the landing trench, one to victims in other
  trenches, and two outside trenches.
- Shields add three armor HP without healing base HP. Damage consumes armor first.
  Armor, heart carrying, and trenches slow gunfire threefold without stacking.
- Med kits restore base HP; healthy cogs leave them. Shields and kits refill in
  30 seconds. All pickups and other cogs are fog-gated for policies.

The game runs at 24 deterministic ticks per second. Coordinates use integer
hundredths of a Polyworld tile on a 6400×4000 arena.

## File policies

Submit a UTF-8 BASIC file. Every seat runs as a BASIC script inside the engine, with the
observations and actuators below; there is no other policy format. (Until version 0.3.33 a
WASM module on the Paintbot sprite protocol was also accepted. That lane is gone: a WASM
upload now forfeits its seat at episode start with an explicit reason, and the sixteen seats
play on. Earlier recordings are unaffected.)

BASIC read-only data: `selfId`, `selfTeam`, `selfX`, `selfY`, `selfHp`, `carrying`,
`homeX`, `homeY`, `heartX`, `heartY`, `ownHeartX`, `ownHeartY`, `ownHeartStolen`,
`worldTick`, `hasGrenade`, `hasSpray`, `armorHp`, `livesLeft`, `grenadeCharge`,
`trenchId` (-1 outside).

Queries: `visible(slot)`, `playerX(slot)`, `playerY(slot)`, `playerHp(slot)`,
`playerCarrying(slot)`, `pickupCount()`, `pickupVisible(id)`, `pickupX(id)`,
`pickupY(id)`, `pickupKind(id)` (0 grenade, 1 spray, 2 medkit, 3 armor),
`glory(team)` (rules 37). Hidden player and pickup coordinates are not disclosed.

Actions: `walkTo(x,y)`, `lookAt(x,y)`, `shootAt(x,y)`, `chargeGrenade(held)`.
Release by calling `chargeGrenade(0)` or not calling it on the next tick.
`shout(stringHandle)` is public communication; PRINT remains private.
Source is limited to 64 KiB, memory to 2 MiB, and each decision to 20,000
instructions / 50,000 work units and a string pool of 1,024 handles / 64 KiB (reset every decision).

## Replays

Replays record accepted actions and per-tick state hashes. Version 6 includes
all equipment state and the approved Paint Crew cog models. The viewer supports
seeking, individual cone visibility, first-person view, event filtering, inventory,
armor/lives inspection, grenade arcs/blasts, spray effects and trench markers.
Earlier replay versions retain their original rules and hashes.

## Comparing two builds on hosted episodes

A hosted experience request runs a batch of episodes you define, on a pinned Coworld, without
touching a league seat. `uv run coworld xp-request create body.json`, then
`uv run coworld xp-request get <xreq_...> --json` for the scores and
`uv run coworld episode-logs <ereq_...> -d <dir>` for the seat logs. For the Jev baseline's own
switches, `coworld/paintbot/tools/jev_experiment.py` writes the arm files and the bodies for
you and prints the upload and create commands; the rest of this section is what to put in a
body it does not cover, and how to read what comes back.

```json
{"target": {"coworld_id": "cow_...", "variant_id": "competition"},
 "roster": [{"slot": 0, "player": {"policy_ref": "my-build:v3"}},
            {"slot": 1, "player": {"policy_ref": "<pvid or name:vN>"}}],
 "num_episodes": 30, "execution_backend": "k8s",
 "episode_player_llm_spend_limit_usd": 0.5, "notes": "what this arm is"}
```

Give the roster one entry per seat, all sixteen (two are shown above) — even seats are Red, odd
are Blue, so seat parity is the team. Two traps in the body itself: `variant_id` belongs in
`target` **or** at the top level, never both, and `policy_ref` takes the bare `name:vN` or a
policy-version UUID, not the player-prefixed `player/name:vN` form that the request echo prints
back. An advised build also needs `episode_player_llm_spend_limit_usd`: a seat with no budget has
no advisor, plays as the baseline and still scores normally, so the request looks healthy and
measures nothing.

Four things about reading the result:

- **The gap between the two scores is one bit; the winner's glory is not.** The loser's glory
  is zeroed at the final tick, so subtracting one side's score from the other only restates who
  won. The winner's number is a real measurement — roughly the match length in seconds minus
  the seconds it took, plus event awards — so it says how *fast* the win was. Which statistic
  to use follows from the matchup. Against an opponent an arm nearly always beats, compare the
  arms' **mean winning glory**: win rate is saturated and carries nothing (two arms both went
  20/20 against the plain BASIC baseline, but their winning glory, 676.7 +/- 83.7 against
  672.6 +/- 91.5 over 20 episodes each, is a comparison with real resolution). Between arms
  that are close, use **win rate**: each arm only has a glory number for the games it won, so
  the means are computed over selected and non-comparable subsets.
- **Split each arm into equal halves with the sides swapped.** Rules 35 mirrored the map and
  validated it at red 51.7% over 400 native seeds, so neither side is favoured — but 60
  episodes of one build against another still came out 35/60 to Red by chance alone
  (95% Wilson [0.457, 0.699]). A 58% split from noise is the same size as the effects these
  batteries are trying to find.
- **Budget the episodes.** 60 episodes give a Wilson interval of about ±0.12: enough to reject
  a 70/30 effect, not enough to tell 0.62 from 0.50. Plan ~250 for that. Decide the stopping
  point and the rule before the first result, and start a fresh battery rather than extending
  one you have already read.
- **Check the seats before trusting a score.** Each seat's BASIC `print` output comes back from
  `coworld episode-logs`; count its asks against its failures and refusals. Locally,
  `PW_BASIC_PEAKS=1` prints each seat's peak instructions, work units and string handles.
- **Read the replay, not just the score.** `examples/paintbot/replay_stats.nim` re-simulates a
  replay and reports, per side, lives left, cogs standing, captures, heart-ticks held, ticks
  spent ahead on heart count and every glory award by kind. Win rate alone hid the most
  important fact about this league: matches end by elimination at roughly a quarter of the
  clock, so the heart meter usually never decides anything. Hosted replays are gzipped —
  `curl -sS <replay_url> | gunzip -c > match.raw` first.

**A league round swaps which side a policy takes between episodes.** Derive the side from that
episode's `policy_version_ids` zipped with slots; never assume your policy is on the even seats.
Assuming it turns a win into a loss in your table, silently.

### What the advisor switches are worth

Measured on 0.3.36 over 420 hosted episodes, every arm 60 head-to-head against the shipped
build with the sides swapped in equal halves (`coworld/paintbot/tools/jev_experiment.py`,
scored by `jev_results.py`). Win rate with a 95% Wilson interval; the loser's glory is zeroed
so the margin says nothing.

| arm | switch | candidate even | candidate odd | pooled | 95% Wilson |
| --- | --- | --- | --- | --- | --- |
| a1-structured | shipped, vs the plain BASIC baseline | 30/30 | 30/30 | **1.000** | [0.940, 1.000] |
| a2-no-nouls | `useNouls = 0` | 0.37 | 0.50 | 0.433 | [0.316, 0.559] |
| a3-score | `useScore = 1` | 0.43 | 0.40 | 0.417 | [0.301, 0.543] |
| a4-margin | `kMargin = 150` | 0.43 | 0.60 | 0.517 | [0.393, 0.638] |
| a5-wide | `useWide = 1` | 0.30 | 0.47 | 0.383 | [0.271, 0.510] |
| a6-retreat | `useRetreat = 1`, `useDial = 1` | 0.70 | 0.47 | 0.583 | [0.457, 0.699] |
| a7-echo | `useEcho = 1` | 0.30 | 0.23 | **0.267** | [0.171, 0.390] |

Only two separate from a coin flip. The advised build beats the plain baseline every time, which
is a sanity check and not a result. And the old echoing relay **loses**: `useEcho = 1` took 16 of
60, consistently on both sides, so the one-voice default is now supported by measurement and not
only by its mechanism.

Everything else is a draw at this power, and the defaults stay as they are. Two of them are worth
reading carefully rather than as weak evidence:

- **a6-retreat looks like the best arm and is not.** Its halves disagree: 0.70 with the candidate
  on even seats against 0.47 on odd. Pooled it is 0.583, which is exactly the split that arose
  from noise alone in the earlier 60-episode battery. An unbalanced battery would have reported
  the retreat choice as promising. This is what the side swap is for.
- **a2-no-nouls does not buy latency.** In a single episode with the two builds on opposite
  sides, the two-question build answered at a median of 26 ticks and the five-question build at
  25, with the five-question build steadier at the tail (p90 78 against 107) and dropping 3% of
  answers as stale against 12%. Questions in one request are evaluated in parallel; asking three
  more costs tokens, not time, so the narrow yes/no questions stay on and keep producing labels.

Separating an effect near 0.60 needs about 250 episodes, not 60, so a draw here is "not measured"
rather than "no difference".

## Heartwick arena

Cottages, garden walls, carts, supply stacks and the market well are solid cover: they block movement, sight and direct fire. Grenades still lob over them. The village is symmetric under a half turn, with a market square, cross streets and side lanes. Flower patches are walkable decoration. Trenches retain their existing movement and damage rules.

### High ground accuracy

Gun spread decreases by 25% per metre above the locked aim point, capped at 50% less spread. Shooting uphill increases spread by up to 50%; level shots are unchanged. Terrain and trench depth both count. This applies to every policy, starting with replay rules version 10.

### Village navigation and nearby speech

Rules 11 widen terrace ramps from 2m to 6m. The baseline assigns high-ground holders and separate flanking lanes, scans when it loses sight of enemies, and holds distance with guns while closing with spray cans.

BASIC uses `shout(strNew("Contact!"))`. Messages are limited to four 256-byte lines per tick. On the next tick, living cogs within 12.8m hear both teams through `heardCount()`, `heardSlot(i)`, `heardX(i)`, `heardY(i)`, and `heardText(i)`. Hearing is independent of the vision cone. The viewer shows speech bubbles for visible living speakers for three seconds.

The equipment baseline remembers visible supplies for ten seconds and equips when it is safe to. Grenade charge follows target distance with a visible-friendly blast check.

Grenade and spray pickups are enlarged, bob, and spin. Each gun shot draws four bright paintballs for readability; this is visual only and still resolves one hit with the existing cooldown.

### Wilderness flanks (rules 12)

Heartwick now has 80m × 48m of playable terrain, 50% more area than the original 64m × 40m village. Coordinates extend from (-800,-400) to (7200,4400) cm, preserving the village, hearts, and equipment positions. Wooded rolling hills and a continuous perimeter trail connect back into the village on all sides. Two BASIC flankers per team use the upper and lower wilderness wings. `mapMinX/Y()` and `mapMaxX/Y()` expose the bounds. Older recordings retain their original boundaries.

Heartwick now spans 120 × 64 metres (twice the preceding wilderness map area).
The original village sits inside wooded hill country with broad saddles, outer
trails, six outlying territory hearts, and four extra medkit stations. Terrain
heights and tree/bush collision bounds are what `terrainHeight` and `walkTo` see.

Baseline routine callouts are staggered across seats every 15 seconds.

New matches use meandering paths with varying widths and curved terrain banks.
The same deterministic land deformation drives heights, ramps, navigation,
and vegetation placement; older recordings keep their original terrain.

Heartwick now occupies an irregular island. The sandy coast slopes into water;
policies and movement respect the shoreline, while all objectives remain connected.

Spray covers a roughly 62-degree cone and deals 3 damage per target per burst; armor absorbs damage first.

### Expanded island and navigation (rules 22)

The island spans 160 × 96 metres, exactly twice the previous map area.
Bounds are (-4800, -2800) to (11200, 6800) centimetres. Six outer hearts
now sit in the expanded wooded hills. BASIC walkTo routes account for body
clearance and traversable slopes; blocked cogs sidestep instead of pushing
forever. Baselines abandon objectives after three seconds without progress.

### Deliberate heart captures (rules 24)

Heart towers show a bar in the capturing team's color. A yellow marker means
capture is contested and paused; the minimap shows the same progress and an
exclamation mark. Capturing an enemy heart takes the same three seconds as a
neutral heart. A different attacking team starts from zero. Capture progress
is recorded in deterministic state hashes and restored when seeking replays.
Rules 23 and older retain their original instant captures and replay hashes.

### Big hearts (rules 25)

Big hearts are twice as large and have a gold ring; the minimap marks them with
`5`. Capture time, capture radius, and ownership rules stay the same. A neutral
big heart earns no points until captured. BASIC `controlPoints(i)` returns 1 or 5
(-1 for an invalid index). Choices are deterministic
for replay verification, and seeking restores both the active heart and used-heart
history. Rules 24 and older retain ordinary one-point hearts.

### Trenches and imperfect hearing (rules 26)

Trenches have dark sunken floors, exposed ochre banks, and timber duckboards.
The tactical map outlines their footprints in tan. Their cover rules are unchanged:
most outside gunfire passes overhead, but grenades landing in the same trench are
especially dangerous, and climbing out is slower.

Nearby movement, gunfire, explosions, and spray produce one-second sound cues.
Sound travels around walls but reveals only a kind, one of eight compass sectors,
and a rough distance band; it reveals no source identity, team, or exact position.
Normal movement is audible within 10 metres, gunfire within 35, explosions within
50, and spray within 18. Cues refresh rather than stack for the same kind and sector,
with at most twelve retained per listener. Dead cogs hear nothing.

BASIC exposes `soundCount()`, `soundKind(i)` (0 footsteps, 1 gunfire, 2 explosion,
3 spray), `soundDirection(i)` (0 E, 1 SE, 2 S, 3 SW, 4 W, 5 NW, 6 N, 7 NE),
`soundDistance(i)` (0 within 6m, 1 within 18m, 2 farther), and `soundAge(i)` in ticks.
Invalid indices return -1. Call `sneak(1)` each tick to move at half speed without
footstep cues; weapons remain audible. Humans hold Q while moving. The selected cog's cues
appear as coarse arcs on the minimap and as brief directional text.

The starter policy turns toward sounds when it has no visible opponent and uses
quiet approaches near objectives. Speech remains a separate existing channel.
Older recordings retain their original mechanics and replay hashes.


### Uniform disguises (rules 27)

Two uniform stations let a cog impersonate the opposing team until it attacks
or dies. Gun windup, a spray burst, or releasing a grenade reveals the cog;
charging a grenade alone does not. A collected uniform respawns after 30 seconds.
The cog's actual team still owns its captures and earns its score. Friendly fire
is enabled for every cog and every weapon, including disguised cogs.

Other agents see the opposite colors and a valid opposing seat number. BASIC
`visible`, `playerX/Y/Hp/Carrying`, `playerTeam`, and `heardSlot` use that observed
identity. The wearer's self identity is unchanged. When both a genuine cog and
its impersonator are visible under the same seat, BASIC reports the nearer body.
`playerTeam(i)` returns the observed team, or -1 when unseen; `hasUniform()`
reports only your own disguise. Pickup kind 4 is a uniform. Spectator scoreboards keep true ownership; bodies and minimap
markers show the disguise. Rules 26 and older keep their original replay hashes.

### Lake (rules 33)

An irregular, enclosed lake sits inland in Heartwick, surrounded by dry land.
Its shallow water is about 38 cm above the carved bed, with sloping banks for
wading. Cogs in the water move at one-quarter speed (7 cm/tick normally),
stacking with sneaking and carrying penalties. Dry banks retain normal speed;
the water causes no damage. Terrain height, line of sight, and navigation use
the lake bed. Earlier replays preserve their original river geometry and rules.

### Glory (rules 37)

(There are no rules 36. Version 0.3.32 stamped its recordings 36 while the live engine still
played rules 35, so a 36 header is read as rules 35 and those replays play back correctly.)

The heart meter decides who wins; glory decides how much the win is worth. Every score the
ladder sees is a winner's glory, so a fast win outranks a slow one, and a team that loses
scores nothing however it played. Glory is a self-imposed handicap: it never pays for anything
that makes a team more likely to win (captures, tags, meter points), only for restraint and
for hardship a team takes on. Each team's glory starts at the match length in seconds (600 for
the ten-minute limit, `endTick div TickRate`) and loses one per second, so a five-minute win
keeps about 300 before events. The events, all constants in `sim.nim`:

| Event | Glory | Credited to |
| --- | --- | --- |
| Thirty seconds with no supply collected (`GloryQuietSupplies`, per team, repeating) | +10 | the abstaining team |
| Friendly fire taken in the opening thirty seconds (`GloryFriendlyFire`, per hit) | +30 | the team that took it |

Spawn protection and self-damage never count; the supply
clock restarts whenever a teammate collects a grenade, spray can, medkit, armor or uniform,
and the countdown floors at zero. At the final tick the loser's glory is set to zero (a draw
zeroes both), then glory is frozen: `scores()` reports each seat's team glory, so the winner's
seats all carry the same number and the loser's carry zero. Glory, the supply clocks and the
recent awards are part of the rules 37 world hash; older recordings ignore them.

The engine keeps each award for four seconds (`gloryEvents`). The viewer shows recent awards
at the very top of the page in the earning team's color ("Ember +10 glory · thirty seconds
without supplies"), the header's big number is each team's glory with the heart-meter points
in small type beside it, and the scoreboard dialog repeats both. `tests/test_paintbot_glory.nim`
covers the countdown, each event, the end-of-match settlement, the hash gate and a rules 37
recording round trip.

### A fair map: mirrored ground (rules 35)

Heartwick is meant to be the same map for both teams under a half turn, and its cottages,
cover, trenches, supplies and hearts were always placed as mirrored pairs. The ground under
them was not: the organic land deformation (rules 15), the coast (rules 16) and the lake
(rules 33) are waves in absolute coordinates, so one team's trench sat on a 2.5 m plateau
overlooking the lake while the other team's sat at its foot, 18% of the lake's shore had a
dry mirror, and the woodland groves were jittered independently. With the same policy on
both sides, red won 27 of 32 hosted matches.

Rules 35 make every wave odd (coordinate shifts) or even (heights) under the half turn:
`shift'(p) = (shift(p) - shift(mirror p)) / 2`, so mirrored points land on mirrored ground;
the groves are placed on the northern half and mirrored; supplies and hearts are nudged free
once and mirrored exactly. `tests/test_paintbot_symmetry.nim` checks heights, water, coast,
cover, trenches, supplies and hearts at every sampled point.

Two things in the engine were also one-sided. Seats act in seat order within a tick, and seats
alternate teams, so red (even seats) moved, collected and sprayed first in every contested
exchange; rules 35 swap each pair of seats on odd ticks. And the `walkTo` path search breaks
ties by scan order (north-west first), so blue's routes were not mirror images of red's; rules
35 route blue on the mirrored map and mirror the answer back. Policies that read the map
(`terrainHeight`, `controlX/Y`, the walkability sprite) need no change; older recordings keep
their terrain, order and hashes.

The baseline itself was also not mirror play: its first squad worked from north of home and its
idle sweep looked east first for both teams, so the two teams' priority squads sat on the same
absolute side of the map. Both are now team-relative (blue plays the half turn of red), in
`base.bas`. Validation, same file on both sides, 400 distinct seeds
each in the native engine: `base.bas` red 51.7% (95% CI 47-57%, p=0.52); a minimal
capture-and-shoot policy red 52.0% (CI 47-57%, p=0.45). Before rules 35 the same `base.bas`
mirror gave red 43% on the old map and 60% on the mirrored map with the old baseline. A policy
that is itself one-sided can of course still favour a seat; the map and engine no longer do.

### Baseline squads, footwork and aim

The BASIC baseline (`players/base.bas`) was rebuilt around four habits. Each cog still runs alone
with fog-gated vision and no shared memory.

- **Aim.** It leads a moving target by the whole gun windup (six moves) and subtracts its own
  drift, because the ray leaves from wherever the shooter stands when the windup ends, along
  the direction locked when the shot was ordered. BASIC cannot read its gun cooldown, so the
  policy keeps its own estimate and only orders a shot at the start of a movement leg that lasts
  the full windup.
- **Footwork.** While an opponent is in sight it moves in short legs of random length across the
  line to the threat instead of walking straight, staying inside the capture ring when it is
  holding one. Randomness comes from a small integer generator seeded by the seat.
- **Squads of four without talking.** Seats 1-4 and 5-8 of a team form two squads. A squad's
  target is a pure function of public heart ownership and the squad number, so all four members,
  including one that has just respawned, choose the same heart. Two members stand in the ring;
  two cover from outside it on the opposing side and step in if nobody is capturing.
- **Refusing bad fights.** A cog that sees more opponents nearby than teammates heads for the
  heart that is far from them and close to it.

It no longer collects spray cans (a can replaces the gun, which loses at range) or uniforms.
Measured in the engine over 100 side-swapped matches it beat the previous baseline 100-0, using
at most 5,670 of the 20,000 instructions and 8,722 of the 50,000 work units per decision, with
no seat disabled. Removing any one habit loses to the full policy (aim 3-37, footwork 12-28,
refusing fights 12-28, squads 16-24 over 40 matches each).

## Advisor oracle (host feature, no rules change)

Seats stay sandboxed and never touch the network. A script may instead draft one request
through typed host functions (below) and let the host ask one operator-configured advisor
endpoint on its behalf. A request is a JSON body `{"state": ..., "questions": {...}}` (at most
32 KiB, 1-64 questions). An ask returns a request id (1 or more), or 0 when refused: no oracle
configured, a request still in flight for this seat, fewer than the minimum ticks since the
seat's last ask (default 24), or an invalid body. Asking never blocks the tick. Polling returns
0 while the request is pending and -1 if it failed (deadline, transport or malformed reply) or
is unknown; at most four answers are kept per seat.

The host sets the endpoint, model and credential from `COGAME_ORACLE_URL` (https only),
`COGAME_ORACLE_MODEL` and `COGAME_ORACLE_KEY`, with `COGAME_ORACLE_INTERVAL` ticks between asks
and `COGAME_ORACLE_DEADLINE` seconds per request. The guest cannot choose any of them. Answers
land on a later tick, so a policy keeps acting on its last answer meanwhile. Replays are
unaffected: they record accepted actions and state hashes, not how a policy chose them, so a
replay of an advised match verifies like any other. Without an oracle, as in certification pods
with no network, every ask returns 0 and matches behave exactly as before.

In hosted Softmax episodes the game pod holds no provider key, so `COGAME_ORACLE_URL` is not used
there. The host finds the platform's LLM sidecar at `AWS_ENDPOINT_URL_BEDROCK_RUNTIME` and posts
to its `/v1/systemone` route, which forwards to Jev (`typesafe/jev-1.13`) on OpenRouter. Each ask
names the asking seat, so its cost counts against that seat's per-episode LLM spend limit for the
league and its requests against that seat's System One bucket: 120 a minute, twice what the
24-tick interval between asks can use. A seat past its request bucket sees asks fail (`-1`) for a
few seconds, until the bucket refills. A seat past its spend limit sees every ask fail for the
rest of the episode, and a league with a $0 limit has no advisor at all. An ask also fails when
its reply does not arrive whole within twice `COGAME_ORACLE_DEADLINE`, or arrives with no answer
the host can use: `oraclePoll` returns `-1` for these, never `0`, so a script waiting on a
request can always tell that it is over. Write the policy so that a
failed or refused ask costs nothing: keep acting on the last answer, or on none.

### The oracle API

A script reaches the oracle through typed host functions; the engine assembles the
JSON, ships it to the host over the policy bridge, and the flattened answer comes back on a later
tick. Everything is int32: string arguments are pool handles (`strNew(...)`), and probabilities,
scores and confidences are scaled by 1000. The draft lives for one decision only, so build it and
call `oracleAsk()` in the same tick.

- `oracleAvailable()` is 1 when the host has an oracle. `oracleReady()` is 0 when a fresh
  `oracleAsk()` would be accepted, the ticks still to wait when it would not, and -1 when there
  is no oracle or this seat already has a request in flight. Drafting costs string operations
  whether or not the request ships, so test it before building anything.
- `oracleState(key, value)`, `oracleStateText(key, text)` add fields to `state` (at most 256);
  `oracleNote(text)` appends to `state.notes` (at most 16). Keys are 1-64 bytes. A key may be a
  **path**: `candidates[0].reach_seconds` builds nested objects and arrays, so facts go out as
  fields rather than spliced into a sentence. A key that is not a well-formed path is used as a
  flat field name.
- `oracleQuestion(key, kind, instructions)` adds a question: kind 0 is a yes/no (`noul`), 1 a
  `score`, 2 a `choice` (1-64 questions). `oracleCriterion(key, label, text)` appends one criterion
  (at most 16): the ordered level text for a score (label ignored), or `label: text` for a yes/no
  (`"true"` / `"false"`) or a choice. `oracleCriterionField(key, label, field, text)` turns one
  criterion into an object - its own text becomes `what` and this adds another field such as
  `not_for` or `examples`; a field name used twice becomes an array. Score criteria take no
  fields.
- `oracleAsk()` returns the request id (1 or more), or 0 when refused for the same reasons as
  `oracle_ask`, when the draft has no question, or when its JSON exceeds 32 KiB. Each call clears
  the draft. Store the id in a global: string handles do not survive the tick, integers do.
- `oraclePoll(id)` is 0 while pending, -1 when failed or unknown, else the number of answers.
  Answers stay readable until four newer ones have arrived for the seat.
- `oracleAnswer(id, key)`: yes/no → P(true) × 1000; score → score × 1000; choice → the index of
  the chosen criterion in the order it was added; -1 when missing.
  `oracleConfidence(id, key)` is the endpoint's confidence × 1000 (-1 when absent) and
  `oracleProbability(id, key, label)` a choice's probability for one label × 1000 (-1 when absent).

`COGAME_ORACLE_LOG=<path>` makes the host append one JSON line per request (slot, id, tick,
latency, the exact request and the raw answers) for offline replay and scoring.

Local evaluation: the hosted league runs in real time, but a local engine runs several times
faster, so answers land tens of ticks late. Set `COGAME_TICK_SECONDS=0.0417` on the host to pace
the bridge to 24 ticks per second, and `PW_BASIC_PEAKS=1` to have the engine print each seat's
peak instructions, work units and string handles at the end of the match.

`examples/paintbot/players/advised.bas` asks every 48 ticks and switches a cog between capturing
and guarding on the answer. Host calls cost work units like any other (`oracleAsk` 68); the
20,000-instruction budget is unchanged, and without an oracle the same script plays as if the calls
were not there.

`players/jev.bas` (manifest entry `basic-jev`, the second BASIC baseline) is `base.bas` with an
advisor layer spliced in by `coworld/paintbot/tools/make_jev_baseline.py`; regenerate it whenever
`base.bas` changes (`--check` in CI keeps the two copies honest). Reflexes stay in code. One cog
per squad asks Jev to pick the squad's objective from a code-ranked list (the three cheapest
capture candidates or keep current) and relays the answer by shout so the squad keeps agreeing.
The facts go out as structured fields - each candidate is a `candidates[k]` row of its owner,
distance, reach time, threat and capture state - and each criterion is one line naming its row,
rather than a sentence with the facts spliced into it. Three narrow yes/no questions ride along
in the same request (outnumbered, a heart of ours falling, the squad arriving together): they
steer nothing, and each is journaled against what the game went on to do so it can be scored.
The draft also carries a retreat choice and a "loses a life" estimate, journaled but switched
off (`useRetreat`, `useDial`, `useWide`, `useScore` in the init block) because they lost
full-length games in the ablations. Asks are event-driven with a 24-tick debounce, and a pick
that arrives more than `kStale` ticks after its ask is dropped rather than applied.

The callout is three words — `Alpha, push Forge.`, `Bravo, hold Chapel.`, `Alpha, carry on.` — and
a listener decodes only the squad word, the verb's first letter and the heart's first letter (A +
index). **Only the asker repeats it**, every two seconds while its answer is fresh; a cog that
adopts a callout falls silent until one of its own asks is answered (`amSpeaker`, gated by
`useEcho = 0`). That is worth knowing for any policy that talks: shouts are heard by *both* teams
within 12.8 m, and each adoption also pushes the listener's objective hold and its leader-takeover
timer out by `kHold`. Before the switch existed every squadmate repeated the callout, which
multiplied the traffic on a channel the enemy can read — one measured episode logged 450 directive
adoptions on the echoing team against 76 on the quiet one — and let two listeners in earshot keep
each other's directive alive indefinitely, so a squad could hold a dead asker's heart forever and
never promote a new asker. `useEcho = 1` restores that behaviour for comparison, and it loses: over two independent
60-episode head-to-head batteries on 0.3.36, sides swapped in equal halves, the echoing build took
42 of 120 (0.350, 95% Wilson [0.271, 0.439], exact two-sided p = 0.0013). Neither battery could be
called on its own — they landed 0.267 and 0.433, which is what a Wilson half-width of 0.12 at n =
60 does to two honest samples.
Where no oracle is configured, as in certification pods (two seats play it there), every ask is
refused and the file plays exactly like `base.bas`: `tests/test_paintbot_jev_baseline.nim` holds
it to the same state hash and checks the drafting cost with the oracle on. The layer was
developed and measured in daveey/cogamer (`cogames/paintbot/jev`): 20 of 24 full-length matches
against `base.bas` through the hosted route, about 100 asks per game.

## Neural BASIC policies

A neural BASIC policy is a ZIP containing exactly `manifest.json`, `policy.bas`,
and `model.bin`. Submit it through the same file-policy upload route as a plain
BASIC source. The BASIC script calls native floating-point inference; it does not
interpret the network's matrix arithmetic or quantize observations to integers.

```basic
paintbot_observe(neuralObservation())
run_neural_net(neuralModel(), neuralObservation(), neuralLogits(), neuralState())
paintbot_act(neuralLogits())
```

The four handle functions identify this seat's model, observation, output, and
recurrent state. Handles cannot access another seat. Each living seat can observe,
infer, and decode one action per tick, in that order. Recurrent state resets on
match start, death, and respawn. The decoder deterministically selects the largest
logit in each action head. Other BASIC actuators remain available for orchestration.

The restricted FP32 actor uses 448 policy-visible inputs, one MinGRU layer of
width 64, 128, or 256, and categorical action heads `[51,25,2,2,2]`. It receives
public objectives, own state, visible apparent identities/pickups, sound cues,
and local terrain; it receives no hidden enemy identities or positions. The
shared training/deployment contract includes public cooldown and heart-meter
information beyond the older BASIC scalar getters.

The bundle manifest uses schema `paintbot-neural-basic/1`, hashes both payloads,
and binds the versioned observation/action contracts. Expanded files are bounded
to 64 KiB BASIC, 16 MiB model, and 8 KiB manifest. Native inference is separately
limited to 4,000,000 counted operations per seat/tick; BASIC's bytecode limits
still apply. Invalid models, buffers, or inference results disable the offending
seat with an explicit policy error and a safe action.

See [package and host API](../../examples/paintbot/neural_basic.md) and
[FP32 actor format](../../examples/paintbot/neural_actor.md) for the exact manifest,
weight layout, reset semantics, and local validation commands. These interfaces
require a game version containing the neural runtime; older game versions accept
only their previously supported policy formats.
