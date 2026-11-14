#!/usr/bin/env bash
# Offline regressions for optional RC diagnostics and private metadata scanning.
# No mounted filesystems, real credentials, Keychain writes or Finder changes.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEMP_PARENT="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
BUILD="$(mktemp -d "${TEMP_PARENT}/DriveStream-upload-safety.XXXXXX")"
cleanup() {
  if [[ -d "${BUILD:?}" && ! -L "${BUILD}" && "${BUILD}" == "${TEMP_PARENT:?}/DriveStream-upload-safety."* && "$(cd "${BUILD}" && pwd -P)" == "${BUILD}" ]]; then
    rm -rf -- "${BUILD}"
  fi
}
trap cleanup EXIT
ARCH="$(uname -m)"
case "${ARCH}" in arm64|x86_64) ;; *) printf 'Unsupported architecture: %s\n' "${ARCH}" >&2; exit 1 ;; esac
SDK="${SWIFT_SDK_PATH:-$(xcrun --sdk macosx --show-sdk-path)}"
mkdir "${BUILD}/inputs"
INPUTS=(
  Sources/Models/UploadSafety.swift
  Sources/Models/RCStatsModels.swift
  Sources/Services/ServiceFileSafety.swift
  Sources/Services/CacheMetadataReader.swift
  Sources/Services/DirtyCacheInspection.swift
  Scripts/UploadSafetyRegressionTests.swift
)
for source in "${INPUTS[@]}"; do
  cp "${ROOT}/${source}" "${BUILD}/inputs/${source##*/}"
done
xcrun swiftc -parse-as-library -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -sdk "${SDK}" -target "${ARCH}-apple-macosx14.0" -module-cache-path "${BUILD}/module-cache" \
  "${BUILD}"/inputs/*.swift -o "${BUILD}/upload-safety-tests"
"${BUILD}/upload-safety-tests"
