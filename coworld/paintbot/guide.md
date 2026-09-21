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
`controlContested(i)` (0 or 1). Invalid indices return -1. WASM sprite observations include
`control heart <index> owner <owner>` and a separate
`control capture <index> team <team> ticks <ticks> contested <0|1>` sprite; the legacy enemy-flag target points to an
unowned objective so existing Paintbot WASM policies can play territory control.

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

Submit either a UTF-8 BASIC file or a WASM module implementing `paintbot_alloc`,
`paintbot_buffer`, `paintbot_step`, `paintbot_output_size`, exported memory and
optional WASI `_initialize`. WASM observations are the Paintbot sprite protocol:
fog-gated equipment labels, grenade flights/targets/blasts, spray puffs, armor, lives,
hearts, and static trench terrain. Replies are either the sprite gamepad (packet `0x84`:
movement, aim buttons, A for gun/spray, C for grenade charge/release) or a **direct order**
(packet `0x85`, 18 bytes: flags, goal x/z, aim x/z as little-endian int32 world cm) that
gives the seat exactly the BASIC actuators: flag 1 walks to the goal with the engine's
pathing (`walkTo`), 16 sets the aim point (`lookAt`), 2 with 16 fires (`shootAt`), 4 holds
the grenade, 8 sneaks. An order lasts one tick, like a BASIC decision; a tick without one
keeps the previous goal and orders nothing new, and a gamepad packet returns the seat to
the gamepad protocol. Chat is packet `0x81`.

BASIC read-only data: `selfId`, `selfTeam`, `selfX`, `selfY`, `selfHp`, `carrying`,
`homeX`, `homeY`, `heartX`, `heartY`, `ownHeartX`, `ownHeartY`, `ownHeartStolen`,
`worldTick`, `hasGrenade`, `hasSpray`, `armorHp`, `livesLeft`, `grenadeCharge`,
`trenchId` (-1 outside).

Queries: `visible(slot)`, `playerX(slot)`, `playerY(slot)`, `playerHp(slot)`,
`playerCarrying(slot)`, `pickupCount()`, `pickupVisible(id)`, `pickupX(id)`,
`pickupY(id)`, `pickupKind(id)` (0 grenade, 1 spray, 2 medkit, 3 armor).
Hidden player and pickup coordinates are not disclosed.

Actions: `walkTo(x,y)`, `lookAt(x,y)`, `shootAt(x,y)`, `chargeGrenade(held)`.
Release by calling `chargeGrenade(0)` or not calling it on the next tick.
`shout(stringHandle)` is public communication; PRINT remains private.
Source is limited to 64 KiB, memory to 2 MiB, and each decision to 20,000
instructions / 50,000 work units and a string pool of 1,024 handles / 64 KiB (reset every decision). WASM instances are isolated in the game pod.

## Replays

Replays record accepted actions and per-tick state hashes. Version 6 includes
all equipment state and the approved Paint Crew cog models. The viewer supports
seeking, individual cone visibility, first-person view, event filtering, inventory,
armor/lives inspection, grenade arcs/blasts, spray effects and trench markers.
Earlier replay versions retain their original rules and hashes.

## Heartwick arena

Cottages, garden walls, carts, supply stacks and the market well are solid cover: they block movement, sight and direct fire. Grenades still lob over them. The village is symmetric under a half turn, with a market square, cross streets and side lanes. Flower patches are walkable decoration. Trenches retain their existing movement and damage rules.

### High ground accuracy

Gun spread decreases by 25% per metre above the locked aim point, capped at 50% less spread. Shooting uphill increases spread by up to 50%; level shots are unchanged. Terrain and trench depth both count. This applies to BASIC and WASM policies, starting with replay rules version 10.

### Village navigation and nearby speech

Rules 11 widen terrace ramps from 2m to 6m. The baseline assigns high-ground holders and separate flanking lanes, scans when it loses sight of enemies, and holds distance with guns while closing with spray cans.

BASIC uses `shout(strNew("Contact!"))`. Messages are limited to four 256-byte lines per tick. On the next tick, living cogs within 12.8m hear both teams through `heardCount()`, `heardSlot(i)`, `heardX(i)`, `heardY(i)`, and `heardText(i)`. Hearing is independent of the vision cone. WASM receives nearby messages as `shout <slot> <text>` labelled sprites at the speaker's position. The viewer shows speech bubbles for visible living speakers for three seconds.

The equipment baseline remembers visible supplies for ten seconds and equips when it is safe to. Grenade charge follows target distance with a visible-friendly blast check. The WASM baseline is the same policy as the BASIC one, ported to the sprite protocol (see "Baseline squads, footwork and aim" below); rebuild with `tools/build_equipment_baseline.py`, a CTF checkout with its Nimby dependencies and wasi-sdk 33. This build used CTF commit `40d0bee8e2c5a8955ff711d96c4c1bb482a69134` for the sprite-frame parser and ABI shim only.

Grenade and spray pickups are enlarged, bob, and spin. Each gun shot draws four bright paintballs for readability; this is visual only and still resolves one hit with the existing cooldown.

### Wilderness flanks (rules 12)

Heartwick now has 80m × 48m of playable terrain, 50% more area than the original 64m × 40m village. Coordinates extend from (-800,-400) to (7200,4400) cm, preserving the village, hearts, and equipment positions. Wooded rolling hills and a continuous perimeter trail connect back into the village on all sides. Two BASIC flankers per team use the upper and lower wilderness wings. `mapMinX/Y()` and `mapMaxX/Y()` expose the bounds; WASM sprites use a translated 1600×960 pixel map with the same five-cm scale. Older recordings retain their original boundaries.

Heartwick now spans 120 × 64 metres (twice the preceding wilderness map area).
The original village sits inside wooded hill country with broad saddles, outer
trails, six outlying territory hearts, and four extra medkit stations. Terrain
heights and tree/bush collision bounds are shared by native and WASM policies.

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
WASM receives the same enlarged geometry through a compressed 3200 × 1920
walkability map, including clearance around obstacles.

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
(-1 for an invalid index). WASM receives `control value <index> points <1|5>`
alongside the unchanged ownership and capture sprites. Choices are deterministic
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
footstep cues; weapons remain audible. Humans hold Q while moving. WASM uses the
B+Select chord (button mask 80), while either button alone retains aim control.
WASM sound sprites are anchored at the listener, with labels
`sound kind <kind> direction <sector> distance <band> age <ticks>`. They do not place sprites at the source. The selected cog's cues
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
reports only your own disguise. Pickup kind 4 is a uniform. WASM receives the
same apparent colors, a `seat N` sprite, a `uniform` pickup, and `uniform worn`
only for itself. Spectator scoreboards keep true ownership; bodies and minimap
markers show the disguise. Rules 26 and older keep their original replay hashes.

### Lake (rules 33)

An irregular, enclosed lake sits inland in Heartwick, surrounded by dry land.
Its shallow water is about 38 cm above the carved bed, with sloping banks for
wading. Cogs in the water move at one-quarter speed (7 cm/tick normally),
stacking with sneaking and carrying penalties. Dry banks retain normal speed;
the water causes no damage. Terrain height, line of sight, and navigation use
the lake bed. Earlier replays preserve their original river geometry and rules.

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

The WASM baseline (`players/base_wasm.nim`, built to `players/baseline.wasm`) is the same policy
ported to the sprite protocol, section for section and with the same constants. It acts through
direct orders (reply packet `0x85`, above), so the engine paths and aims for it exactly as for the
BASIC seat; the differences are that the frame's gun-ready icon replaces BASIC's cooldown
estimate and that the `carrying` branches of the BASIC file, dead in territory play, are not
ported. `test_baseline.py` checks the territory contract (reach an unowned heart, hold the ring
through the capture timer, retarget). Measured through the hosted runtime over 32 side-swapped matches against `base.bas` it is
17-15 (95% CI 36-69%), with interchangeable combat totals (246 against 234 shots, 94 against
92 hits, 30 deaths each); red won 27 of those 32 whichever policy sat there. It beats the
previous gamepad-only WASM baseline 16-0 over 16 side-swapped matches.

## Advisor oracle (host feature, no rules change)

Seats stay sandboxed and never touch the network. A WASM policy may instead import two host
functions from module `paintbot` and let the host ask one operator-configured advisor
endpoint on its behalf:

- `oracle_ask(ptr: i32, len: i32) -> i32` hands over a UTF-8 JSON body `{"state": ..., "questions": {...}}`
  (at most 32 KiB, 1-64 questions). It returns a request id (1 or more), or 0 when refused: no
  oracle configured, a request still in flight for this seat, fewer than the minimum ticks since
  the seat's last ask (default 24), or an invalid body. Asking never blocks the tick.
- `oracle_poll(id: i32, ptr: i32, cap: i32) -> i32` copies the answer, the endpoint's `answers`
  object as compact JSON, into the guest buffer and returns its length. It returns 0 while the
  request is pending, -1 if it failed (deadline, transport or malformed reply) or is unknown, and
  -2 if `cap` is too small. An answer is delivered once; at most four unread answers are kept per seat.

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
league and its requests against that seat's bucket: 30 a minute, which is why the hosted interval
between asks is 48 ticks rather than 24. A seat past either limit sees its asks fail (`-1`) until
the limit clears; a league with a $0 limit has no advisor at all. Write the policy so that a
failed or refused ask costs nothing: keep acting on the last answer, or on none.

### BASIC seats

A BASIC script reaches the same oracle through typed host functions; the engine assembles the
JSON, ships it to the host over the policy bridge, and the flattened answer comes back on a later
tick. Everything is int32: string arguments are pool handles (`strNew(...)`), and probabilities,
scores and confidences are scaled by 1000. The draft lives for one decision only, so build it and
call `oracleAsk()` in the same tick.

- `oracleAvailable()` is 1 when the host has an oracle.
- `oracleState(key, value)`, `oracleStateText(key, text)` add fields to `state` (at most 128);
  `oracleNote(text)` appends to `state.notes` (at most 16). Keys are 1-64 bytes.
- `oracleQuestion(key, kind, instructions)` adds a question: kind 0 is a yes/no (`noul`), 1 a
  `score`, 2 a `choice` (1-64 questions). `oracleCriterion(key, label, text)` appends one criterion
  (at most 16): the ordered level text for a score (label ignored), or `label: text` for a yes/no
  (`"true"` / `"false"`) or a choice.
- `oracleAsk()` returns the request id (1 or more), or 0 when refused for the same reasons as
  `oracle_ask`, when the draft has no question, or when its JSON exceeds 32 KiB. Each call clears
  the draft. Store the id in a global: string handles do not survive the tick, integers do.
- `oraclePoll(id)` is 0 while pending, -1 when failed or unknown, else the number of answers.
  Answers stay readable until four newer ones have arrived for the seat.
- `oracleAnswer(id, key)`: yes/no → P(true) × 1000; score → score × 1000; choice → the index of
  the chosen criterion in the order it was added; -1 when missing.
  `oracleConfidence(id, key)` is the endpoint's confidence × 1000 (-1 when absent) and
  `oracleProbability(id, key, label)` a choice's probability for one label × 1000 (-1 when absent).

Local evaluation: the hosted league runs in real time, but a local engine runs several times
faster, so answers land tens of ticks late. Set `COGAME_TICK_SECONDS=0.0417` on the host to pace
the bridge to 24 ticks per second, and `PW_BASIC_PEAKS=1` to have the engine print each seat's
peak instructions, work units and string handles at the end of the match.

`examples/paintbot/players/advised.bas` asks every 48 ticks and switches a cog between capturing
and guarding on the answer. Host calls cost work units like any other (`oracleAsk` 68); the
20,000-instruction budget is unchanged, and without an oracle the same script plays as if the calls
were not there.
