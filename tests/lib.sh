#!/usr/bin/env bash
# Common helpers for nvim headless tests.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Run headless nvim with only this plugin on the runtimepath (no user config).
run_nv() {
	nvim --headless --noplugin -u NONE --cmd "set rtp^=$REPO_ROOT" "$@"
}
export -f run_nv
export REPO_ROOT
