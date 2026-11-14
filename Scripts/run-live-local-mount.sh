#!/usr/bin/env bash
# Explicit opt-in actual local NFS mount. Never uses Google, user's app config,
# Finder preferences, Keychain writes, or a system-wide rclone installation.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
[[ $# -eq 2 ]] || { printf 'Usage: %s /absolute/verified/rclone SHA256\n' "$0" >&2; exit 1; }
TEMP_PARENT="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
BUILD="$(mktemp -d "${TEMP_PARENT}/DriveStream-live-build.XXXXXX")"
cleanup() {
  if [[ "${BUILD:?}" == "${TEMP_PARENT:?}/DriveStream-live-build."* && -d "${BUILD}" && ! -L "${BUILD}" ]]; then
    rm -rf -- "${BUILD}"
  fi
}
trap cleanup EXIT
SDK="${SWIFT_SDK_PATH:-$(xcrun --sdk macosx --show-sdk-path)}"
ARCH="$(uname -m)"
xcrun swiftc -parse-as-library -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -sdk "${SDK}" -target "${ARCH}-apple-macosx14.0" -module-cache-path "${BUILD}/module-cache" \
  "${ROOT}"/Sources/Models/*.swift "${ROOT}"/Sources/Services/*.swift \
  "${ROOT}/Scripts/LocalMountIntegrationTests.swift" -o "${BUILD}/live-mount-tests"
"${BUILD}/live-mount-tests" "$1" "$2"
