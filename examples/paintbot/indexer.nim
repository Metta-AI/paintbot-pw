## Worker entry point: identical replay verification, no graphics/assets/policies.
import std/os
import flatty
import game, analysis
when defined(emscripten): {.emit: "#include <emscripten.h>".}

try:
  setup()
  if not replayMode: raise newException(ValueError, "A replay is required")
  let index = indexReplay(proc(tick, total: int) =
    when defined(emscripten):
      {.emit: "EM_ASM({postMessage({type:'progress',tick:$0,total:$1});}, `tick`, `total`);".})
  writeFile("/episode.index", index.toFlatty())
except CatchableError:
  writeFile("/index.error", getCurrentExceptionMsg())
