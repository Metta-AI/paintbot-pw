# Native fast-XP worker

The fast-XP server launches one `paintbot_worker` process per game using the
COGAME file handoff. Each game runs on one CPU thread, without pacing, a
container, or the hosted policy bridge. Oracle/JEV calls are unavailable.

Build with this checkout's pinned Nim dependencies and libarchive development
headers and libraries:

```sh
nim c coworld/paintbot/paintbot_worker.nim
nim c coworld/paintbot/replay_check.nim
nim r tests/test_paintbot_packages.nim
```

The worker accepts raw UTF-8 BASIC or the production `paintbot-neural-basic/1`
and `/2` packages. ZIP entries are read with bounded decompression and CRC
validation, then checked against the manifest hashes. Native policy loading
validates the model and observation/action contracts. Invalid packages forfeit
their seat; BASIC compilation failures fail the game through the COGAME failure
file. The worker writes a replay, results, seat status, seat logs and a
`timings.json` file next to the results. Its `gameplay_ms` measures the tick loop,
including bot execution and recording frames, but excludes setup and final writes.

The API server owns fetching, caching, deadlines, batching and log visibility.
Run that server with `FAST_XP_GAME=paintbot-pw` and
`FAST_XP_PAINTBOT_WORKER` pointing at this executable. The server lives in
Metta-AI/polyworld under `coworld/fast_xp`.

Verify every state hash in a saved replay with:

```sh
coworld/paintbot/replay_check --replay match.replay
```

To generate the test ZIP used by the server's integration test, pass an output
path to `nim r tests/test_paintbot_packages.nim /tmp/paintbot-fixture.zip`.
