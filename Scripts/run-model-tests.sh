#!/usr/bin/env bash
# Compile the non-UI application sources and regression tests in Swift 6 mode.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEMP_PARENT="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
BUILD_DIR="$(mktemp -d "${TEMP_PARENT}/DriveStream-model-build.XXXXXX")"
cleanup() {
  if [[ -d "${BUILD_DIR:?}" && ! -L "${BUILD_DIR}" && "${BUILD_DIR}" == "${TEMP_PARENT:?}/DriveStream-model-build."* ]]; then
    rm -rf -- "${BUILD_DIR}"
  else
    printf 'Refusing cleanup of an unexpected model-test directory.\n' >&2
  fi
}
trap cleanup EXIT
ARCH="$(uname -m)"
case "${ARCH}" in
  arm64|x86_64) ;;
  *) printf 'Unsupported architecture: %s\n' "${ARCH}" >&2; exit 1 ;;
esac
# Bash 3.2 treats an empty array as unset with set -u. Always supply an SDK.
SDK="${SWIFT_SDK_PATH:-$(xcrun --sdk macosx --show-sdk-path)}"
[[ -d "${SDK}" ]] || { printf 'Invalid Swift SDK path.\n' >&2; exit 1; }
SDK_ARGS=(-sdk "${SDK}")
SERVICES=()
for source in "${ROOT}"/Sources/Services/*.swift; do
  # MountController integrates UI windows/notifications and has its own lifecycle
  # suite; all other service/model code can be tested using only the CLT.
  [[ "${source##*/}" == "MountController.swift" ]] || SERVICES+=("${source}")
done
xcrun swiftc \
  -parse-as-library -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -target "${ARCH}-apple-macosx14.0" \
  -module-cache-path "${BUILD_DIR}/module-cache" \
  "${SDK_ARGS[@]}" \
  "${ROOT}"/Sources/Models/*.swift \
  "${SERVICES[@]}" \
  "${ROOT}/Scripts/ModelSmokeTests.swift" \
  -o "${BUILD_DIR}/model-tests"
"${BUILD_DIR}/model-tests"

# Quota boundaries must also be checked when only the Command Line Tools are available.
cat > "${BUILD_DIR}/quota-tests.swift" <<'SWIFT'
import Foundation

@main
struct QuotaSafetySmokeTests {
    static func main() throws {
        let cases: [(String, RcloneAbout, Int64?)] = [
            ("overflow", RcloneAbout(used: Int64.max, free: 1), nil),
            ("both components at maximum", RcloneAbout(used: Int64.max, free: Int64.max), nil),
            ("exact boundary", RcloneAbout(used: Int64.max - 1, free: 1), Int64.max),
            ("full boundary", RcloneAbout(used: Int64.max, free: 0), Int64.max),
            ("explicit total precedence", RcloneAbout(total: 100, used: Int64.max, free: 1), 100),
            ("explicit maximum total", RcloneAbout(total: Int64.max, used: Int64.max, free: Int64.max), Int64.max),
            ("normal fallback", RcloneAbout(used: 40, free: 60), 100),
            ("full fallback", RcloneAbout(used: 40, free: 0), 40),
            ("zero total fallback", RcloneAbout(total: 0, used: 40, free: 60), 100),
            ("negative total fallback", RcloneAbout(total: -1, used: 40, free: 60), 100),
            ("missing free", RcloneAbout(used: 40), nil),
            ("missing used", RcloneAbout(free: 60), nil),
            ("missing both", RcloneAbout(), nil),
            ("negative used", RcloneAbout(used: -1, free: 100), nil),
            ("negative free", RcloneAbout(used: 100, free: -1), nil),
            ("negative extremes", RcloneAbout(used: Int64.min, free: Int64.min), nil),
            ("zero capacity", RcloneAbout(used: 0, free: 0), nil),
            ("zero used", RcloneAbout(used: 0, free: 100), 100),
            ("zero used boundary", RcloneAbout(used: 0, free: Int64.max), Int64.max)
        ]
        for (name, about, expected) in cases {
            precondition(about.effectiveTotal == expected, "About quota \(name)")
            print("ok - About quota \(name)")
        }
        let overflow = try JSONDecoder().decode(RcloneAbout.self, from: Data(#"{"used":9223372036854775807,"free":1}"#.utf8))
        precondition(overflow.used == Int64.max && overflow.effectiveTotal == nil, "Decoded About overflow")
        let boundary = try JSONDecoder().decode(RcloneAbout.self, from: Data(#"{"used":"9223372036854775806","free":"1"}"#.utf8))
        precondition(boundary.used == Int64.max - 1 && boundary.effectiveTotal == Int64.max, "Decoded About boundary")
        print("ok - About decoded quota boundaries")
    }
}
SWIFT
xcrun swiftc \
  -parse-as-library -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -target "${ARCH}-apple-macosx14.0" \
  -module-cache-path "${BUILD_DIR}/module-cache" \
  "${SDK_ARGS[@]}" \
  "${ROOT}/Sources/Models/RCStatsModels.swift" "${BUILD_DIR}/quota-tests.swift" \
  -o "${BUILD_DIR}/quota-tests"
"${BUILD_DIR}/quota-tests"
