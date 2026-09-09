#!/usr/bin/env bash
set -euo pipefail
exec "$(dirname "${BASH_SOURCE[0]}")/../../tools/build_replay_viewer.sh" call_to_adventure cta "$1"
