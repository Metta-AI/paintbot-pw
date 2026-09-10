# Paintbot PW

Capture-the-heart Paintbot built on the Polyworld engine, following its Gods of the Arena integration. Sixteen seats, two teams, one pod. Submit either a raw BASIC program or a Paintbot-CDX WASM reactor; mixed rosters are supported.

- [Game rules and policy API](coworld/paintbot/guide.md)
- [BASIC baseline](examples/paintbot/players/base.bas)
- [Original WASM baseline](coworld/paintbot/players/baseline.wasm)
- [Polyworld engine documentation](docs/POLYWORLD.md)

## Run locally

Requires Nim 2.2.6 or newer and Python 3.12.

```sh
python3 coworld/tools/sync_dependencies.py
export POLYWORLD_DEPS="$PWD/tmp/coworld/deps"
nim c -d:headless -o:tmp/paintbot examples/paintbot/paintbot.nim
./tmp/paintbot --bot examples/paintbot/players/base.bas:16 --ticks 7200 --record tmp/match.replay
./tmp/paintbot --replay tmp/match.replay
nim r tests/test_paintbot.nim
```

For the hosted BASIC/WASM runtime:

```sh
python3 -m venv .venv
.venv/bin/pip install wasmtime==48.0.0 boto3
nim c -d:coworld -o:tmp/paintbot-coworld examples/paintbot/paintbot.nim
.venv/bin/python coworld/paintbot/local.py --policy coworld/paintbot/players/baseline.wasm --ticks 240 --output tmp/wasm-match
```

Pass `--policy` sixteen times for a mixed roster. The host accepts local, HTTPS and S3 policy URIs with mandatory SHA-256 and size verification. Coworld stages uploaded files automatically.

## Browser replay viewer and package

With Emscripten installed and Python 3.12 on PATH:

```sh
coworld/paintbot/tools/build_replay_viewer.sh "$PWD/tmp/viewer"
python3 -m http.server 8765
# Open http://localhost:8765/tmp/viewer/index.html?replay=/tmp/match.replay
coworld build --project coworld/paintbot --version 0.1.0
coworld upload-coworld coworld/paintbot/dist/coworld_manifest.json --wait-certification
```

The viewer resimulates recorded actions and checks every tick hash. Policy source is never included in replays.

## WASM provenance

`baseline.wasm` is the unchanged public CDX baseline, SHA-256
`135538c4a166f3f0ac370204c6c0b90ddd7ed825490e1cc161fa161a8640c2e9`.
Its Nim source, WASI build configuration and build script are available at
[Metta-AI/cogame-paintbot-cdx, commit 40d0bee8](https://github.com/Metta-AI/cogame-paintbot-cdx/tree/40d0bee8e2c5a8955ff711d96c4c1bb482a69134/singlepod).
The bundled BASIC baseline translates the objectives and core combat strategy; it is not instruction-for-instruction equivalent to the larger Nim policy. See the guide for the exact compatibility scope.
