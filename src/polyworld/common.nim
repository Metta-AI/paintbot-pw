## Shared paths and constants for Polyworld.
## Native games load assets from the sibling polyworld_data folder.
## Wasm packs that folder at /polyworld_data.

const
  DataRoot* =
    when defined(emscripten):
      "/polyworld_data"
    else:
      "../polyworld_data"
