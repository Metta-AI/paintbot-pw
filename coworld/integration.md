# Polyworld Coworld integration

`-d:coworld` selects a native headless server. The wrapper is imported only by
Coworld builds. Desktop, ordinary headless, and WASM builds do not import Mummy.
`-d:emscripten -d:replayViewer` selects the static replay bootstrap and enables
looping. Each game retains its simulation, BASIC resource limits and early endings.

The packages are `coworld/gota`, `coworld/lvd`, and `coworld/cta`. Each contains a
manifest template, Compose definition, unchanged BASIC baseline, game guide and
executable viewer build hook. Generated packages and test outputs are ignored.

## Build

Use Nim 2.2.10, Emscripten, Docker, Python 3, and Coworld tooling from Metta commit
`9b99c8e18a763850bc6e04f331db98caf7fd645d` or a compatible later revision. That
revision includes James Boggs's merged game-hosted file-player workflow. Use a
separate Metta checkout so an existing development checkout stays intact.

```sh
python3 coworld/tools/sync_dependencies.py
export POLYWORLD_DEPS="$PWD/tmp/coworld/deps"
coworld build --project coworld/gota --version 2026.9.9.1
coworld build --project coworld/lvd --version 2026.9.9.1
coworld build --project coworld/cta --version 2026.9.9.1
```

`nimby.lock` pins ordinary dependencies. `coworld/dependencies.lock` pins the same
revisions plus optional Mummy. `sync_dependencies.py --latest` resolves upstream
HEADs and updates both locks; ordinary builds never update revisions implicitly.
The build hook validates the asset commit in `coworld/assets.json`. `POLYWORLD_DATA`
can point at a checkout of that revision. Per-game `webdata.txt` files include only
selected models, their referenced textures, and the assets loaded by each renderer.
Run `select_assets.py` after changing those dependencies or asset references.

## Runtime

The runner supplies local `file://` URIs through `COGAME_CONFIG_URI`,
`COGAME_PLAYER_SEATS_URI`, `COGAME_RESULTS_URI`, `COGAME_SAVE_REPLAY_URI`, and
`COGAME_PLAYER_FAILURE_URI`. Configurations require the game's fixed-length tokens
and players arrays. Staged policy filenames may have no extension. Raw BASIC source
is read from the disk with bounded reads and compiled with the existing game limits.

Every seat log is created before compilation. PRINT and BASIC diagnostics stay in
that seat's log, bounded to 10 MiB including the truncation marker. A runtime error
disables that VM. A compilation error closes the logs and publishes a sanitized
player failure marker. Successful episodes finish the replay, close all logs, write
optional player status, and atomically rename the results file last. The HTTP server
runs on a separate thread and stays available until the runner terminates it.

The legacy `/global` WebSocket exists only for current platform contract probes: one
status message and exact Ping/Pong. Gameplay uses files. `/healthz` is live;
`/client/global` and other legacy clients show a static page. Unimplemented routes
return HTTP 501. No player artifact ZIP is produced.

## Verification

`tools/verify_native.sh` checks all desktop, headless and Coworld entrypoints,
recording regression tests, and full replay verification. First record full matches
into `tmp/coworld/{gota,lvd,cta}.replay` with the ordinary headless binaries and
`--record PATH`. `tools/test_runtime.py` uses the binaries in `tmp/coworld` to check
extensionless and empty sources, slot-specific print output, compilation failure,
disabled VMs, health/Ping/Pong, completion ordering and the 10 MiB log bound.

Serve the repository over HTTP to run `tools/test_browser.py`. It checks actual
WASM rendering and full replay hashes, seeking, speed, iframe resizing, readiness,
and visible errors. It supports a host Chrome executable or container Chromium for
ARM and x86 coverage. `tools/replay_probe.html` captures the Softmax iframe protocol.

CTA replay game version 15 adds authoritative per-hero banked gold and return flags.
They are cloned, restored and hashed with the world. Surviving returned heroes tied
for the most banked gold receive 1; every other hero receives 0. The other games also
emit binary scores in zero-based platform slot order. Platform Elo remains the
standings algorithm.

## Release acceptance

Certify locally and against the local Softmax stack before publishing. Upload with
`--wait-certification` and require hosted certification and smoke to succeed. Create
leagues only after their releases become canonical. Declare one visible Competition
division, configure separate baseline filler versions, submit the baseline entrant,
and then enable scheduling with a 30-minute round interval. Fillers must never be
submitted as ranked entrants.

Record canonical Coworld IDs, league/division/policy IDs, certification evidence,
experience requests, three successful league rounds including an automatic cycle,
and game/player log plus browser replay evidence in the release handoff.
