import std/os
import "../../src/polyworld/emscripten.nims"
when defined(replayIndexer):
  --os:linux
  --cpu:wasm32
  --cc:clang
  --clang.exe:emcc
  --clang.linkerexe:emcc
  --threads:off
  --gc:arc
  --exceptions:goto
  --define:noSignalHandler
  --define:useMalloc
  --undef:nimTypeNames
  switch("nimcache", thisDir() / "emscripten/indexer-cache")
  switch("passL", "-o " & thisDir() / "emscripten/paintbot-index.js" &
    " -O3 -sMODULARIZE -sEXPORT_NAME=PaintbotIndex -sENVIRONMENT=worker" &
    " -sINVOKE_RUN=0 -sEXIT_RUNTIME=0 -sALLOW_MEMORY_GROWTH -sMAXIMUM_MEMORY=4GB" &
    " -sEXPORTED_RUNTIME_METHODS=FS,callMain")
else:
  setupEmscripten(thisDir())

when defined(emscripten) and not defined(replayIndexer):
  switch("passL", "--preload-file " & thisDir() / "../../tmp/paintbot-cover.glb" & "@/paintbot-cover.glb")

when defined(emscripten) and not defined(replayIndexer):
  for team in ["red", "blue", "red-blue", "blue-red"]:
    switch("passL", "--preload-file " & thisDir() / ("../../tmp/paintbot-cog-" & team & ".glb") & "@/paintbot-cog-" & team & ".glb")

when defined(emscripten) and not defined(replayIndexer):
  switch("passL", "--preload-file " & thisDir() / "../../tmp/round-village.glb" & "@/round-village.glb")

when defined(emscripten) and not defined(replayIndexer):
  # The expanded woodland can exceed the default 2 GiB while baking foliage.
  # Memory grows on demand; this is a ceiling, not a startup allocation.
  switch("passL", "-s MAXIMUM_MEMORY=4GB")
  # Reuse freed foliage buffers through Emscripten malloc rather than
  # exhausting the WASM address space with Nim allocator fragmentation.
  switch("define", "useMalloc")
  switch("undef", "nimTypeNames")
