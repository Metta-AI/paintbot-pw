## Shared Emscripten compile recipe for Polyworld games.

import
  std/[os, strformat, strutils]

proc setupEmscripten*(exampleDir: string) =
  ## Configures the wasm backend and writes the bundle next to the game.
  when defined(emscripten):
    let
      repoDir = exampleDir / ".." / ".."
      dataDir = repoDir / ".." / "polyworld_data"
      outputDir = exampleDir / "emscripten"
      shellFile = repoDir / "src" / "polyworld" / "emscripten.html"
    if not dirExists(outputDir):
      mkDir(outputDir)
    switch("nimcache", outputDir / "tmp")
    switch("threads", "off")
    --os:linux
    --cpu:wasm32
    --cc:clang
    when defined(windows):
      --clang.exe:emcc.bat
      --clang.linkerexe:emcc.bat
      --clang.cpp.exe:emcc.bat
      --clang.cpp.linkerexe:emcc.bat
    else:
      --clang.exe:emcc
      --clang.linkerexe:emcc
      --clang.cpp.exe:emcc
      --clang.cpp.linkerexe:emcc
    --listCmd
    --gc:arc
    --exceptions:goto
    --define:noSignalHandler
    --debugger:native
    --define:noAutoGLerrorCheck
    --define:flatty64
    when not defined(debug):
      --define:release
    switch(
      "passL",
      (&"""
      -o {outputDir / projectName()}.html
      --preload-file {dataDir}@/polyworld_data
      --pre-js {repoDir / "src" / "polyworld" / "webinputs.js"}
      --shell-file {shellFile}
      -s ASYNCIFY
      -s FETCH
      -s USE_WEBGL2=1
      -s MAX_WEBGL_VERSION=2
      -s MIN_WEBGL_VERSION=1
      -s FULL_ES3=1
      -s GL_ENABLE_GET_PROC_ADDRESS=1
      -s ALLOW_MEMORY_GROWTH
      --profiling
      """).replace("\n", " ")
    )
    if paramStr(1) == "run" or paramStr(1) == "r":
      setCommand("c")
      echo "To run the Emscripten build, use:"
      echo "emrun " & outputDir / (projectName() & ".html")
