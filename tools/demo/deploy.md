# Static live demo

The three-column page runs BASIC bots in the browser:

https://softmaxdash-nginx.tail0f4a29.ts.net/polyworld/demo/

Build ordinary WASM clients, without `-d:replayViewer`, before packaging:

```sh
export POLYWORLD_DEPS="$PWD/tmp/coworld/deps"
nim c -d:emscripten examples/gods_of_the_arena/gota.nim
nim c -d:emscripten examples/light_vs_dark/lvd.nim
nim c -d:emscripten examples/call_to_adventure/cta.nim
python3 tools/demo/package.py tmp/polyworld-site --release UNIQUE_RELEASE
```

The output contains `demo/index.html` and a versioned `releases/UNIQUE_RELEASE`
directory. Each game has its HTML, JavaScript, WASM, asset bundle, and unchanged
`base.bas`. The page uses relative URLs and seats 10 GotA bots, 2 LvD bots, and
4 CtA bots. Each iframe can also run as a standalone page. No game server or
connection to the developer's machine is needed.

Looping starts enabled. Each game runs its live bots for the first match, then
replays that recorded match continuously. The transport's loop button can turn
repeating off. Opening a replay file also starts with looping enabled.

Each game shows asset download progress, followed by world initialization,
until its first rendered frame. Progress uses the decoded bundle size so gzip
transfers remain accurate. Failed downloads and bot loads stay visible.
Packaging removes local build directories from Emscripten's data labels.

Copy the release directory to `/var/www/polyworld/releases/` on
`ec2-user@52.54.192.246`, verify its `manifest.json` hashes, and then atomically
replace `/var/www/polyworld/demo/index.html` with the generated page. Keep older
release directories so already-open pages can finish loading their assets.
Generated bundles and upload staging belong in the ignored `tmp/` directory.

The existing `/etc/nginx/conf.d/softmaxdash.conf` serves `/polyworld/` directly
from `/var/www`, with gzip sidecars, WASM MIME types, and cache revalidation.
`/polyworld/demo` redirects to `/polyworld/demo/`. Tailscale provides HTTPS to
nginx on `127.0.0.1:8080`; the other dashboard routes retain their proxy to
`127.0.0.1:8930`. Validate changes with `sudo nginx -t` before reloading nginx.

The initial release is `c685fe7-20260909`, built from Polyworld commit
`c685fe7` with the navigation fix. Its manifest records the full revision,
dependency lock hash, and every runtime file's size and SHA-256 digest.
The previous nginx configuration is backed up on the server at
`/etc/nginx/conf.d/softmaxdash.conf.polyworld-c685fe7-20260909.bak`.
