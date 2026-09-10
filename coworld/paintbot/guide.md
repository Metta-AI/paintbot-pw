# Paintbot PW

Paintbot on Polyworld: a deterministic 3D paintball arena for sixteen agents.
Red controls even slots and Blue controls odd slots. Capture the enemy heart
and bring it home while your own heart is home. Three captures win. A time
limit without a capture victory is a draw; all agents receive zero.

Players move through a symmetric seeded bunker arena. Paintballs travel and
collide with cover; three hits tag a player out. Tagged players drop the heart
and respawn after 72 ticks, with 36 ticks of spawn protection. A dropped heart
returns after 240 ticks, or when its team touches it. Carrying slows movement
to 70 percent. Matches run at 24 deterministic ticks per simulated second,
with no wall-clock pacing on the server.

## Submit either file type

Upload one raw BASIC source file or one Paintbot reactor WASM file. File type
is detected from the WASM magic bytes, not its extension. The game runs both
inside its pod; there are no player pods. BASIC uses Polyworld's bounded VM.
WASM uses Wasmtime with no filesystem/network/environment grants, 256 MiB
memory per seat, bounded fuel, and an epoch deadline. Mixed rosters work.

The WASM entrypoints and Sprite-v1 packets match `cogame-paintbot-cdx`:
`paintbot_init`, `paintbot_buffer`, `paintbot_step`, `paintbot_output_size`,
exported memory, and optional WASI `_initialize`. The unchanged CDX baseline
is bundled as `players/baseline.wasm`. Observations contain the walkability
map, fog-gated avatars and HP, hearts, endzones, and own aim. Movement, fire,
and aim masks are translated to Polyworld actions. Chat is accepted but has
no gameplay effect. This version has no grenade, pickup, battle-royale, or
Season 2 play-call mechanics. It preserves the file interface, not identical
combat trajectories or old replay files.

## BASIC interface

Coordinates are integer hundredths of a Polyworld tile, with x right and y
down on a 6400×4000 map. Slots are zero-based, Red=0 and Blue=1.

Read-only data: `selfId`, `selfTeam`, `selfX`, `selfY`, `selfHp`, `carrying`,
`homeX`, `homeY`, `heartX`, `heartY`, `ownHeartX`, `ownHeartY`,
`ownHeartStolen`, `worldTick`.

Queries: `visible(slot)`, `playerX(slot)`, `playerY(slot)`, `playerHp(slot)`,
`playerCarrying(slot)`. Hidden enemies yield no coordinates. Enemy heart
coordinates fall back to its home when its carrier is not visible.

Actions: `walkTo(x,y)` uses bounded cover navigation; `shootAt(x,y)` fires
when the gun is ready. Source is limited to 64 KiB, VM memory to 2 MiB,
and each decision to 20,000 instructions/50,000 work units. PRINT stays in
private seat logs. A BASIC runtime error disables its VM.

`players/base.bas` reimplements the baseline's carrier-first objectives,
heart recovery, defensive roles, wounded-target focus and short movement
lead in BASIC. It is a strategic translation, not an action-identical port
of every tuning flag in the larger Nim policy. Use the original WASM file
for the original policy code.

## Replays

Action-only Polyworld tapes contain accepted commands and portable per-tick
hashes, never policy source. The native verifier and browser replay renderer
resimulate those actions. The viewer has play/pause, speed and seeking.
