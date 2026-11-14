#!/usr/bin/env bash
# Offline security fixtures by default. Optional interoperability executes ONLY a
# caller-supplied checksum-verified official rclone, never OAuth or a user config.
# Usage: ./Scripts/run-security-tests.sh [--rclone /absolute/path --rclone-sha256 HEX]
set -euo pipefail
ROOT="${DRIVESTREAM_ROOT:-$(dirname "${BASH_SOURCE[0]}")/..}"
ROOT="$(builtin cd "${ROOT}" && pwd -P)"
ARCH="$(uname -m)"
case "${ARCH}" in arm64|x86_64) ;; *) echo "Unsupported architecture: ${ARCH}" >&2; exit 1 ;; esac
if [[ -n "${DRIVESTREAM_SECURITY_SDK:-}" ]]; then
  SDK="${DRIVESTREAM_SECURITY_SDK}"
elif [[ "${DEVELOPER_DIR:-$(xcode-select -p)}" == /Library/Developer/CommandLineTools && -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
  SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
else
  SDK="$(xcrun --sdk macosx --show-sdk-path)"
fi
[[ -d "${SDK}" ]] || { echo "Real macOS SDK unavailable: ${SDK}" >&2; exit 1; }
BUILD_DIR="$(mktemp -d /private/tmp/DriveStream-security-build.XXXXXX)"
cleanup() {
  # Resolve and verify the exact absolute path before any destructive cleanup.
  if [[ "${BUILD_DIR:?}" == /private/tmp/DriveStream-security-build.* && -d "${BUILD_DIR}" && ! -L "${BUILD_DIR}" && "$(builtin cd "${BUILD_DIR}" && pwd -P)" == "${BUILD_DIR}" ]]; then
    rm -rf -- "${BUILD_DIR}"
  else
    echo "Refusing cleanup of unexpected security build directory" >&2
  fi
}
trap cleanup EXIT
mkdir "${BUILD_DIR}/snapshot"
SOURCES=(
  Sources/Services/ServiceFileSafety.swift Sources/Services/ProcessLaunchEnvironment.swift
  Sources/Services/CommandRunner.swift Sources/Services/RcloneObscuration.swift
  Sources/Services/RcloneCredentialTransport.swift Sources/Services/RclonePrivateConfig.swift
  Sources/Services/KeychainHelper.swift Sources/Services/RcloneConfigService.swift
  Sources/Services/RcloneDriveRootService.swift
  Sources/Services/FileDownloader.swift Sources/Services/DependencyArchiveSafety.swift
  Sources/Services/DependencyManager.swift Scripts/SecurityRegressionTests.swift
)
# Copy all inputs before compiling: concurrent source edits must not affect the build.
# All models are included so additive policy/event dependencies do not break this suite.
for model in "${ROOT}"/Sources/Models/*.swift; do
  cp "${model}" "${BUILD_DIR}/snapshot/$(basename "${model}")"
done
for source in "${SOURCES[@]}"; do
  cp "${ROOT}/${source}" "${BUILD_DIR}/snapshot/$(basename "${source}")"
done
xcrun swiftc -parse-as-library -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -sdk "${SDK}" -target "${ARCH}-apple-macosx14.0" \
  -module-cache-path "${BUILD_DIR}/module-cache" \
  "${BUILD_DIR}"/snapshot/*.swift -o "${BUILD_DIR}/security-tests"
"${BUILD_DIR}/security-tests" "$@"
