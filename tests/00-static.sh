#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

if command -v stylua >/dev/null 2>&1; then
	stylua --check .
else
	echo "stylua not found, skipping style check"
fi
find lua plugin -name '*.lua' -print0 | xargs -0 -n1 luac -p
