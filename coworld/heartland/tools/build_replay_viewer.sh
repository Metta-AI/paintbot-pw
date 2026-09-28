#!/usr/bin/env bash
# Heartland replays are paintbot-pw replays (FFA-kin mode): the same viewer bundle.
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../paintbot/tools/build_replay_viewer.sh" "$1"
