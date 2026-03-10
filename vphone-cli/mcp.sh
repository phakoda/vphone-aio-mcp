#!/bin/zsh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${SCRIPT_DIR}"

./build_and_sign.sh >&2

exec ./.build/release/vphone-mcp
