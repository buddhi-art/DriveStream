#!/usr/bin/env bash
# Fast/offline pin tests: only private fixtures; no mount, network, preferences or Xcode.
set -euo pipefail
ROOT="$(builtin cd "${DRIVESTREAM_ROOT:-$(dirname "${BASH_SOURCE[0]}")/..}" && pwd -P)"
TEMP_PARENT="$(builtin cd "${TMPDIR:-/tmp}" && pwd -P)"
BUILD_DIR="$(mktemp -d "${TEMP_PARENT}/DriveStream-pin-build.XXXXXX")"
cleanup() {
  if [[ "${BUILD_DIR:?}" == "${TEMP_PARENT:?}/DriveStream-pin-build."* && -d "${BUILD_DIR}" && ! -L "${BUILD_DIR}" && "$(builtin cd "${BUILD_DIR}" && pwd -P)" == "${BUILD_DIR}" ]]; then
    rm -rf -- "${BUILD_DIR}"
  else
    printf 'Refusing cleanup of unexpected pin build directory.\n' >&2
  fi
}
trap cleanup EXIT
ARCH="$(uname -m)"
case "${ARCH}" in arm64|x86_64) ;; *) printf 'Unsupported architecture.\n' >&2; exit 1 ;; esac
if [[ -n "${SWIFT_SDK_PATH:-}" ]]; then
  SDK="${SWIFT_SDK_PATH}"
elif [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
  SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
else
  SDK="$(xcrun --sdk macosx --show-sdk-path)"
fi
[[ -d "${SDK}" ]] || { printf 'Invalid Swift SDK path.\n' >&2; exit 1; }
mkdir "${BUILD_DIR}/models"
# Compile a frozen copy: concurrent app/model editing cannot modify compiler inputs.
cp "${ROOT}/Sources/Models/StreamConfig.swift" "${BUILD_DIR}/models/"
cp "${ROOT}/Sources/Models/GoogleSharedDrive.swift" "${BUILD_DIR}/models/"
cp "${ROOT}/Sources/Models/RCStatsModels.swift" "${BUILD_DIR}/models/"
cp "${ROOT}/Sources/Models/MountState.swift" "${BUILD_DIR}/models/"
cp "${ROOT}/Sources/Models/PerformancePolicy.swift" "${BUILD_DIR}/models/"
xcrun swiftc \
  -parse-as-library -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -target "${ARCH}-apple-macosx14.0" -sdk "${SDK}" \
  -module-cache-path "${BUILD_DIR}/module-cache" \
  "${BUILD_DIR}/models/StreamConfig.swift" \
  "${BUILD_DIR}/models/GoogleSharedDrive.swift" \
  "${BUILD_DIR}/models/RCStatsModels.swift" \
  "${BUILD_DIR}/models/MountState.swift" \
  "${BUILD_DIR}/models/PerformancePolicy.swift" \
  "${ROOT}/Sources/Services/PinTraversal.swift" \
  "${ROOT}/Sources/Services/PinFileIO.swift" \
  "${ROOT}/Sources/Services/PinEngine.swift" \
  "${DRIVESTREAM_PIN_TEST_SOURCE:-${ROOT}/Scripts/PinEngineTests.swift}" \
  -o "${BUILD_DIR}/pin-tests"
"${BUILD_DIR}/pin-tests"
