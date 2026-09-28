import std/os

const
  DataRoot* =
    when defined(emscripten):
      "/polyworld_art"
    else:
      getEnv("POLYWORLD_ART", "../polyworld_art")
  TmpRoot* =
    when defined(emscripten):
      "/tmp"
    else:
      "tmp"
