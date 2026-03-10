#!/bin/zsh
# build_and_sign.sh — Build vphone binaries and sign with private entitlements.
#
# Requires: SIP/AMFI disabled (amfi_get_out_of_my_way=1)
#
# Usage:
#   zsh build_and_sign.sh           # build + sign
#   zsh build_and_sign.sh --install # also copy both binaries to ../bin
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="${SCRIPT_DIR}/.build/release"
BINARY_CLI="${BIN_DIR}/vphone-cli"
BINARY_MCP="${BIN_DIR}/vphone-mcp"
ENTITLEMENTS="${SCRIPT_DIR}/vphone.entitlements"

print "=== Building vphone binaries ==="
cd "${SCRIPT_DIR}"
swift build -c release 2>&1 | tail -5

print ""
print "=== Signing with entitlements ==="
print "  entitlements: ${ENTITLEMENTS}"
for binary in "${BINARY_CLI}" "${BINARY_MCP}"; do
  print "  signing: ${binary}"
  codesign --force --sign - --entitlements "${ENTITLEMENTS}" "${binary}"
done
rm -rf "${SCRIPT_DIR}/vphone.app"
print "  signed OK"

# Verify entitlements
print ""
print "=== Entitlement verification ==="
for binary in "${BINARY_CLI}" "${BINARY_MCP}"; do
  print "  ${binary}"
  codesign -d --entitlements - "${binary}" 2>/dev/null | head -20
done

print ""
print "=== Binaries ==="
ls -lh "${BINARY_CLI}" "${BINARY_MCP}"

if [[ "${1:-}" == "--install" ]]; then
  REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
  mkdir -p "${REPO_ROOT}/bin"
  cp -f "${BINARY_CLI}" "${REPO_ROOT}/bin/vphone-cli"
  cp -f "${BINARY_MCP}" "${REPO_ROOT}/bin/vphone-mcp"
  print ""
  print "Installed to ${REPO_ROOT}/bin/vphone-cli"
  print "Installed to ${REPO_ROOT}/bin/vphone-mcp"
fi

print ""
print "Done. Run with:"
print "  ${BINARY_CLI} --rom <rom> --disk <disk> --serial"
print "  ${BINARY_MCP}"
