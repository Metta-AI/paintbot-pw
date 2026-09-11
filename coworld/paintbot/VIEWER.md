# Paintbot PW spectator viewer

The viewer uses the same Polyworld character, toon, terrain, prop, and sun-shadow renderers as Gods of the Arena. Art is pinned by `coworld/assets.json`. Masonry bunkers are generated from exact game collision dimensions; cosmetic grass and border scenery do not alter the simulation.

## CTF feature correspondence

Reference: `coworld-ctf/client/replay_broadcast.html`, with the newer communications drawer in `cogame-paintbot-cdx/client/replay_broadcast.html`.

| CTF spectator capability | Paintbot PW |
| --- | --- |
| Team score, flags/hearts, living squad pips | Team plates, capture scores, heart state, 16 selectable portraits and health/respawn status |
| Player inspection and K/D roster | Live health, tags/outs, captures, respawn, shield, carrying, coordinates; full scoreboard at the playhead |
| Kill feed and flag/capture announcements | Exact attacker/victim tag events, pickups/drops/returns/captures; capture banner and paint bursts |
| Momentum / glory timeline | Tag + capture momentum, clickable event marks, spoilers hidden by default |
| Play/pause, restart, back-tick, +5s, end | All supported, plus forward one tick; 1/2/4/16x speed |
| Scrubbing and tick deep links | Range scrubber, `?t=<tick>` opens paused; independent 240-tick seek checkpoints |
| Loop and auto-skip lulls | Loop restarts playback; lull skip jumps to two seconds before the next event |
| Minimap, camera pan/zoom | Tactical minimap navigation, camera footprint, zoom buttons/slider, drag pan, Shift-drag orbit, pinch, deliberate Ctrl-scroll |
| POV visibility lens | Individual bot or collective team vision, using actual range and cover checks |
| First-person inset, resize grip, tactical context | Second 3D camera, pointer/keyboard resize handle; selected bot and facing wedge on full-context minimap |
| Comms, expand/collapse, jump to live | Initially collapsed, team filters, time-correct public shouts, pinned scrolling; no private diagnostic logs |
| Endcard / result roster | Final outcome and per-seat scoreboard, still able to seek back into the match |
| Keyboard and embedded host protocol | Shortcuts in `?`; loading/ready/error messages, first-error-wins, hash failures stop playback |
| Mobile layout | Compact roster, touch pan/pinch, one-tap bot POV and second-tap clear, minimap and all replay controls |

Fullscreen, replay download, top-down camera, order traces, and a searchable-by-type event list are also available.

The viewer displays finite lives, armor, grenade pickups/throws/blasts, spray pickups/bursts, med kits, and trenches. The active league is a two-team ladder; campaign maps live in Observatory outside the episode viewer.

## Replay compatibility and public comms

The viewer reads original v1 files and v2 files. V2 adds bounded player display names and public policy shouts; recorded inputs and world hashes are unchanged. Old files show numbered team seats because names/comms were never recorded. Previously published episodes retain their original viewer bundle; new episodes use the newly published package.

WASM public shout packets are recorded. BASIC policies can explicitly publish a shout with `result = shout(strNew("Guard the heart"))`. BASIC `PRINT` remains a private diagnostic log. Shouts are currently spectator messages; they do not add a new policy observation channel. BASIC permits four shouts per seat per tick, maximum 1024 bytes per string; the replay caps public messages at 20,000.

## Build

Check out `Metta-AI/polyworld-data` beside this repository as `polyworld_data` at the revision in `coworld/assets.json`, or set `POLYWORLD_DATA`. Run `python3 coworld/tools/sync_dependencies.py`, then:

```
coworld/paintbot/tools/build_replay_viewer.sh "$PWD/tmp/viewer"
```

The bundle contains its fonts, portrait, textures and models; it needs no external CDN. The native graphical executable also needs `python3 coworld/paintbot/tools/build_cover.py` before launch from the repository root.

## Verification

`tests/test_paintbot_replay.nim` checks forward/backward/repeated checkpoint seeks against recorded hashes, v1 conversion, v2 public metadata, invalid metadata, and hash corruption. The existing seven rules tests and four Python runtime-boundary tests remain passing. A newly recorded 16-seat mixed BASIC/WASM episode retained the existing 3984-tick, 3–0 result and hash `1977552757`.

## Live browser games and human control

The bundle includes `play/index.html`, built as an ordinary Emscripten client,
using the same shared `webinputs.js`, `controllers.nim`, and `player.nim` as
Gods of the Arena. Reference: Polyworld `53625e903ee64d6fc938e46613247f8c5d395279`,
`tools/demo/deploy.md` and `examples/gods_of_the_arena/controls.nim`.

The viewer's **Watch live demo** runs sixteen bundled BASIC bots in the browser.
**Play as human** reserves seat 1 for you and loads fifteen bots. Right-click to
move or attack an enemy; Shift-right-click shoots at the ground. Hold C and
release to throw a carried grenade. Human commands use the bot command stream
and are recorded with the same world hashes. Rewind to review the action; use
**Return to live** to resume control. Download saves the recorded match.
These are local browser matches; the league's running server match is separate.

Standalone URLs: `play/index.html?bot=base.bas:16` to spectate or
`play/index.html?bot=base.bas:15&player=1` to play. `player=N` uses the shared
one-based seat contract. File replays preserve their recorded players.
