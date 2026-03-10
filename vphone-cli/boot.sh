#!/bin/zsh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${SCRIPT_DIR}"

./build_and_sign.sh

exec ./.build/release/vphone-cli \
    --rom "${SCRIPT_DIR}/VM/AVPBooter.vresearch1.bin" \
    --disk "${SCRIPT_DIR}/VM/Disk.img" \
    --nvram "${SCRIPT_DIR}/VM/nvram.bin" \
    --cpu 16 \
    --memory 8192 \
    --serial-log "${SCRIPT_DIR}/VM/serial.log" \
    --stop-on-panic \
    --stop-on-fatal-error \
    --sep-rom "${SCRIPT_DIR}/VM/AVPSEPBooter.vresearch1.bin" \
    --sep-storage "${SCRIPT_DIR}/VM/SEPStorage" \
    --vnc-experimental
