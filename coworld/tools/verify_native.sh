#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
export POLYWORLD_DEPS="$PWD/tmp/coworld/deps"
mkdir -p tmp/coworld/checks
for spec in 'gota gods_of_the_arena 10 recordGota' 'lvd light_vs_dark 2 recordLvd' 'cta call_to_adventure 4 recordCta'; do
  read -r entry directory count flag <<< "$spec"
  for mode in desktop headless coworld; do
    flags=("--hints:on")
    if [[ "$mode" != desktop ]]; then flags+=("-d:$mode"); fi
    nim check "${flags[@]}" "examples/$directory/$entry.nim" > "tmp/coworld/checks/$entry-$mode.log" 2>&1
  done
  nim check -d:headless "-d:$flag" tests/test_recordings.nim > "tmp/coworld/checks/$entry-recording-check.log" 2>&1
  nim r -d:headless "-d:$flag" tests/test_recordings.nim "--bot:examples/$directory/players/base.bas:$count" > "tmp/coworld/checks/$entry-recording.log" 2>&1
  "tmp/coworld/$entry-native" --replay "tmp/coworld/$entry.replay" > "tmp/coworld/checks/$entry-full-replay.log" 2>&1
  nim c -d:coworld "-o:tmp/coworld/$entry" "examples/$directory/$entry.nim" > "tmp/coworld/checks/$entry-build.log" 2>&1
  echo "$entry: desktop, headless, Coworld, recordings and full replay passed"
done
nim check tests/tests.nim > tmp/coworld/checks/tests-check.log 2>&1
nim r tests/tests.nim > tmp/coworld/checks/tests.log 2>&1
