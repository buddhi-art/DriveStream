#!/usr/bin/env bash
# Offline service regressions; only CLT/Swift and macOS system frameworks required.
# No OAuth, Keychain writes, network downloads, consent, installer, or Drive mount.
set -euo pipefail
ROOT="${DRIVESTREAM_ROOT:-$(dirname "${BASH_SOURCE[0]}")/..}"
TEST_SOURCE="${DRIVESTREAM_SERVICE_TEST_SOURCE:-${ROOT}/Scripts/ServiceSafetyTests.swift}"
ARCH="$(uname -m)"
case "${ARCH}" in arm64|x86_64) ;; *) echo "Unsupported architecture: ${ARCH}" >&2; exit 1 ;; esac
TEMP_PARENT="${TMPDIR:-/tmp}"
# pwd -P resolves aliases such as /tmp -> /private/tmp before cleanup decisions.
TEMP_PARENT="$(builtin cd "${TEMP_PARENT}" && pwd -P)"
BUILD_DIR="$(mktemp -d "${TEMP_PARENT}/DriveStream-service-build.XXXXXX")"
cleanup() {
  if [[ "${BUILD_DIR:?}" == "${TEMP_PARENT:?}/DriveStream-service-build."* && -d "${BUILD_DIR}" && ! -L "${BUILD_DIR}" ]]; then
    rm -rf -- "${BUILD_DIR}"
  else
    echo "Refusing cleanup of unexpected build directory" >&2
  fi
}
trap cleanup EXIT
SERVICES=()
for source in "${ROOT}"/Sources/Services/*.swift; do
  [[ "${source##*/}" == "MountController.swift" ]] || SERVICES+=("${source}")
done
xcrun swiftc \
  -parse-as-library -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -target "${ARCH}-apple-macosx14.0" \
  -module-cache-path "${BUILD_DIR}/module-cache" \
  "${ROOT}"/Sources/Models/*.swift \
  "${SERVICES[@]}" \
  "${TEST_SOURCE}" -o "${BUILD_DIR}/service-tests"
"${BUILD_DIR}/service-tests"
