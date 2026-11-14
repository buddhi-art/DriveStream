#!/usr/bin/env bash
# Parse or typecheck the real app, with no substitute State wrapper or macro shim.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
MODE="${1:-typecheck}"
case "${MODE}" in parse|typecheck) ;; *) printf 'Use parse or typecheck.\n' >&2; exit 1 ;; esac
TEMP_PARENT="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
BUILD_DIR="$(mktemp -d "${TEMP_PARENT}/DriveStream-swift-check.XXXXXX")"
cleanup() {
  if [[ -d "${BUILD_DIR:?}" && ! -L "${BUILD_DIR}" && "${BUILD_DIR}" == "${TEMP_PARENT:?}/DriveStream-swift-check."* ]]; then
    rm -rf -- "${BUILD_DIR}"
  fi
}
trap cleanup EXIT
ARCH="$(uname -m)"
# Keep real SwiftUI available on CLT-only preview installations. The current
# preview SDK may require a macro plugin shipped only with full Xcode; an installed
# stable SDK uses Apple's real State wrapper, never a substitute implementation.
if [[ -n "${SWIFT_SDK_PATH:-}" ]]; then
  SDK="${SWIFT_SDK_PATH}"
elif [[ "${DEVELOPER_DIR:-$(xcode-select -p)}" == /Library/Developer/CommandLineTools && -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
  SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
else
  SDK="$(xcrun --sdk macosx --show-sdk-path)"
fi
[[ -d "${SDK}" ]] || { printf 'Invalid Swift SDK path.\n' >&2; exit 1; }
SDK_ARGS=(-sdk "${SDK}")
xcrun swiftc \
  -"${MODE}" -parse-as-library -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -target "${ARCH}-apple-macosx14.0" -module-cache-path "${BUILD_DIR}/module-cache" \
  "${SDK_ARGS[@]}" \
  "${ROOT}"/Sources/App/*.swift "${ROOT}"/Sources/Models/*.swift \
  "${ROOT}"/Sources/Services/*.swift "${ROOT}"/Sources/Views/*.swift
printf 'Real Swift sources passed %s in Swift 6 complete-concurrency mode.\n' "${MODE}"
