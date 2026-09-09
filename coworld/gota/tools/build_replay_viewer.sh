#!/usr/bin/env bash
set -euo pipefail
exec "$(dirname "${BASH_SOURCE[0]}")/../../tools/build_replay_viewer.sh" gods_of_the_arena gota "$1"
