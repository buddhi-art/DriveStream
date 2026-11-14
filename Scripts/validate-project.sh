#!/usr/bin/env bash
# Generate a complete Xcode project in isolation, leaving the workspace unchanged.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEMP_PARENT="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
BUILD_DIR="$(mktemp -d "${TEMP_PARENT}/DriveStream-project-check.XXXXXX")"
cleanup() {
  if [[ -d "${BUILD_DIR:?}" && ! -L "${BUILD_DIR}" && "${BUILD_DIR}" == "${TEMP_PARENT:?}/DriveStream-project-check."* ]]; then
    rm -rf -- "${BUILD_DIR}"
  fi
}
trap cleanup EXIT
mkdir "${BUILD_DIR}/repo"
cp "${ROOT}/project.yml" "${BUILD_DIR}/repo/project.yml"
cp -R "${ROOT}/Sources" "${ROOT}/Resources" "${BUILD_DIR}/repo/"
if [[ -d "${ROOT}/Tests" ]]; then cp -R "${ROOT}/Tests" "${BUILD_DIR}/repo/"; fi
"${XCODEGEN:-xcodegen}" generate --spec "${BUILD_DIR}/repo/project.yml" --project "${BUILD_DIR}/repo"
test -s "${BUILD_DIR}/repo/DriveStream.xcodeproj/project.pbxproj"
printf 'XcodeGen clean-tree generation passed; no workspace project was changed.\n'
