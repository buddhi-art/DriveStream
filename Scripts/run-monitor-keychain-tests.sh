#!/usr/bin/env bash
# Offline lifecycle/Keychain regressions against real source snapshots. All
# monitors, notification centers, and SecItem operations exercised are fakes.
# No user Keychain access/authentication UI, Google, helpers, mounts, or settings.
set -euo pipefail
ROOT="${DRIVESTREAM_ROOT:-$(dirname "${BASH_SOURCE[0]}")/..}"
ROOT="$(builtin cd "${ROOT}" && pwd -P)"
ARCH="$(uname -m)"
case "${ARCH}" in arm64|x86_64) ;; *) echo "Unsupported architecture: ${ARCH}" >&2; exit 1 ;; esac
if [[ -n "${SWIFT_SDK_PATH:-}" ]]; then
  SDK="${SWIFT_SDK_PATH}"
elif [[ "${DEVELOPER_DIR:-$(xcode-select -p)}" == /Library/Developer/CommandLineTools && -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
  SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
else
  SDK="$(xcrun --sdk macosx --show-sdk-path)"
fi
[[ -d "${SDK}" ]] || { echo "Real macOS SDK unavailable: ${SDK}" >&2; exit 1; }
BUILD_PARENT="${MONITOR_KEYCHAIN_BUILD_PARENT:-/private/tmp}"
BUILD_PARENT="$(builtin cd "${BUILD_PARENT}" && pwd -P)"
BUILD_DIR="$(mktemp -d "${BUILD_PARENT}/DriveStream-monitor-keychain.XXXXXX")"
cleanup() {
  # Check the exact resolved creation path and prefix before removing any files.
  if [[ "${BUILD_DIR:?}" == "${BUILD_PARENT:?}"/DriveStream-monitor-keychain.* && -d "${BUILD_DIR}" && ! -L "${BUILD_DIR}" && "$(builtin cd "${BUILD_DIR}" && pwd -P)" == "${BUILD_DIR}" ]]; then
    rm -rf -- "${BUILD_DIR}"
  else
    echo "Refusing cleanup of unexpected monitor/Keychain build directory" >&2
  fi
}
trap cleanup EXIT
mkdir "${BUILD_DIR}/snapshot"
SOURCES=(
  Sources/Services/DeviceLifecycleMonitor.swift Sources/Services/KeychainHelper.swift
  Sources/Services/RcloneCredentialTransport.swift Sources/Services/RcloneConfigService.swift
  Sources/Services/RcloneDriveRootService.swift
  Sources/Services/RclonePrivateConfig.swift Sources/Services/RcloneObscuration.swift
  Sources/Services/CommandRunner.swift Sources/Services/ProcessLaunchEnvironment.swift
  Sources/Services/ServiceFileSafety.swift Sources/Services/DependencyManager.swift
  Sources/Services/DependencyArchiveSafety.swift Sources/Services/FileDownloader.swift
  Scripts/MonitorKeychainTests.swift
)
# Compile immutable snapshots, including real models and credential transport;
# no redefinitions/stubs of production errors, KeychainHelper, or lifecycle types.
for model in "${ROOT}"/Sources/Models/*.swift; do
  cp "${model}" "${BUILD_DIR}/snapshot/$(basename "${model}")"
done
for source in "${SOURCES[@]}"; do
  cp "${ROOT}/${source}" "${BUILD_DIR}/snapshot/$(basename "${source}")"
done
FLAGS=(-parse-as-library -swift-version 6 -strict-concurrency=complete -warnings-as-errors)
if [[ "${MONITOR_KEYCHAIN_TEST_TSAN:-0}" == "1" ]]; then
  FLAGS+=(-sanitize=thread)
fi
xcrun swiftc "${FLAGS[@]}" -sdk "${SDK}" -target "${ARCH}-apple-macosx14.0" \
  -module-cache-path "${BUILD_DIR}/module-cache" \
  "${BUILD_DIR}"/snapshot/*.swift -o "${BUILD_DIR}/monitor-keychain-tests"
"${BUILD_DIR}/monitor-keychain-tests"
