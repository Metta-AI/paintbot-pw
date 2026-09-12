# Replay startup

Artwork is gzip-compressed at packaging time (including on servers that do not
compress octet-stream responses). The replay and live demo share one archive.
The unused modular character file and portraits are excluded; legacy terrain
packs remain available for historical recordings.

The small `index-worker.js` / `paintbot-index.wasm` worker runs the same Nim
`indexReplay` used by native validation, concurrently with artwork downloads.
It verifies every recorded state hash and sends the index/checkpoints through
Flatty to the viewer. No externally supplied index is accepted. Worker failures
remain replay failures, not successful partial verification. Native playback
continues to index directly. Build both worker and viewer together; their
serialization ABI must match.

Textured foliage and props retain one GPU vertex buffer per model, plus small
placement buffers. Instanced color and alpha-cutout shadow passes apply the
same position, rotation, stretch and tint as the old baked vertices. This avoids
allocating, transforming and uploading millions of duplicate foliage vertices
on every load. Other Polyworld games use the same renderer.

Startup reports artwork bytes, background verification progress, terrain,
textures, village, mesh upload and first-frame preparation. Phase boundaries
yield through Emscripten Asyncify so status updates can paint. Failures and a
two-minute startup timeout remain visible.

## Validation (2026-09-11 local date)

Same public 42-second replay:
`2dd1d266-47a7-4b34-8153-9d5c9887364c.replay`.

- Artwork: 81,697,723 bytes before; 62,012,616 decoded / 40,637,207 gzip bytes after.
- Worker WASM: approximately 360 KiB; no artwork or graphics dependency.
- Original published viewer with local assets: ready at 16.991 s, one 16.590 s
  main-thread task. The instrumented original warm reload took 11.087 s.
- Updated local viewer: ready at 7.515 s. Verification finished at 1.208 s in
  the worker. Mesh upload/baking took 0.143 s versus 6.134–9.897 s before.
- These are observed local timings, not a network speed guarantee. Original
  cold production artwork transfer was 27.729 s; the new archive is 50% smaller.
- Browser checked terrain/foliage/shadows, live BASIC demo, historical v3 and
  v23 replays. A modified replay was rejected at hash mismatch tick 1.
- Native replay tests include index serialization and hash-checked seeks,
  historical metadata and corrupt inputs. JS input tests and Nim checks pass.

Build with `coworld/paintbot/tools/build_replay_viewer.sh <output-directory>`.
The packaging step checks replay/live asset layouts match before sharing them.
