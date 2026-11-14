#!/usr/bin/env bash
# Real-source Swift 6 lifecycle regressions with private fake helpers/inspectors.
# No user rclone, OAuth/browser, installer, actual mounts, or Keychain writes.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
PYTHON="${PYTHON:-python3}"
if ! command -v "${PYTHON}" >/dev/null 2>&1; then
  echo "python3 is required for lifecycle fixtures" >&2
  exit 1
fi
PYTHON_PATH="$(command -v "${PYTHON}")"
# /tmp is intentional: StreamConfig disallows /private/var mount points. All
# paths still resolve to one freshly created, private test directory at cleanup.
TEMP_DIR="$(mktemp -d /tmp/drivestream-lifecycle.XXXXXX)"
EXPECTED_REAL="$("${PYTHON_PATH}" -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "${TEMP_DIR}")"
TEST_PID=""
cleanup() {
  local status=$?
  trap - EXIT INT TERM
  if [[ -n "${TEST_PID}" ]]; then
    local child
    for child in $(jobs -pr); do
      if [[ "${child}" == "${TEST_PID}" ]]; then
        kill "${TEST_PID}" 2>/dev/null || true
      fi
    done
    wait "${TEST_PID}" 2>/dev/null || true
    # Emergency cleanup after compiler/test interruption. Each record identifies
    # a fixture child of this exact test binary; verify its current command still
    # names our private fixture before signalling, guarding against reused PIDs.
    "${PYTHON_PATH}" - "${TEMP_DIR}" "${TEST_PID}" <<'PY'
import json, os, signal, subprocess, sys, time
from pathlib import Path
root, parent = Path(sys.argv[1]), int(sys.argv[2])
owned_prefixes = (str(root) + "/", str(root.resolve()) + "/")
def is_owned(pid):
    result = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "command="], capture_output=True, text=True)
    return any(prefix in result.stdout for prefix in owned_prefixes) and "/support/bin/rclone" in result.stdout
pids = set()
for path in root.glob("*/support/events.jsonl"):
    for line in path.read_text().splitlines():
        try:
            event = json.loads(line)
            if event["ppid"] == parent:
                pids.add(event["pid"])
        except (ValueError, KeyError):
            pass
for pid in pids:
    if not isinstance(pid, int) or pid <= 1:
        continue
    if not is_owned(pid):
        continue
    try:
        os.kill(pid, signal.SIGTERM)
        deadline = time.monotonic() + 1
        while time.monotonic() < deadline and is_owned(pid):
            time.sleep(0.02)
        # Revalidate before escalation; never signal a reused or unrelated PID.
        if is_owned(pid):
            os.kill(pid, signal.SIGKILL)
            deadline = time.monotonic() + 1
            while time.monotonic() < deadline and is_owned(pid):
                time.sleep(0.02)
    except ProcessLookupError:
        pass
PY
  fi
  local resolved
  resolved="$("${PYTHON_PATH}" -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "${TEMP_DIR:?}")"
  # Verify this exact absolute target, the creation-time resolved path, and its
  # known prefix immediately before removing anything. Never follow a symlink.
  case "${TEMP_DIR:?}" in
    /tmp/drivestream-lifecycle.*)
      if [[ "${resolved}" == "${EXPECTED_REAL:?}" && -d "${TEMP_DIR}" && ! -L "${TEMP_DIR}" ]]; then
        rm -rf -- "${TEMP_DIR:?}"
      else
        echo "Refusing unexpected lifecycle temporary path: ${TEMP_DIR}" >&2
      fi
      ;;
    *) echo "Refusing unexpected lifecycle temporary path: ${TEMP_DIR}" >&2 ;;
  esac
  exit "${status}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Compile immutable snapshots; another coding agent may edit the working tree.
BUILD="${TEMP_DIR}/build"
mkdir -p "${BUILD}/module-cache"
"${PYTHON_PATH}" - "${ROOT}" "${BUILD}" <<'PY'
import shutil, sys
from pathlib import Path
root, build = map(Path, sys.argv[1:])
shutil.copytree(root / "Sources", build / "Sources")
shutil.copyfile(root / "Scripts/MountLifecycleTests.swift", build / "MountLifecycleTests.swift")
PY

SELECTED_DEVELOPER="${DEVELOPER_DIR:-$(xcode-select -p)}"
if [[ -n "${SWIFT_SDK_PATH:-}" ]]; then
  SDK="${SWIFT_SDK_PATH}"
elif [[ "${SELECTED_DEVELOPER}" == /Library/Developer/CommandLineTools && -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
  SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
else
  SDK="$(xcrun --sdk macosx --show-sdk-path)"
fi
ARCH="$(uname -m)"
case "${ARCH}" in
  arm64|x86_64) ;;
  *) echo "Unsupported architecture: ${ARCH}" >&2; exit 1 ;;
esac
SOURCES=()
for group in Models Services Views App; do
  for source in "${BUILD}/Sources/${group}"/*.swift; do
    [[ -f "${source}" ]] || continue
    # Only omit the actual @main app entry. AppDelegate/views are compiled as
    # real sources for their shared symbols, but never instantiated by tests.
    if [[ "${source##*/}" != "DriveStreamApp.swift" ]]; then
      SOURCES+=("${source}")
    fi
  done
done
FLAGS=(-parse-as-library -swift-version 6 -strict-concurrency=complete -warnings-as-errors)
if [[ "${LIFECYCLE_TEST_TSAN:-0}" == "1" ]]; then
  FLAGS+=(-sanitize=thread)
fi
BIN="${BUILD}/MountLifecycleTests"
xcrun swiftc "${FLAGS[@]}" -sdk "${SDK}" -target "${ARCH}-apple-macosx14.0" \
  -module-cache-path "${BUILD}/module-cache" "${SOURCES[@]}" \
  "${BUILD}/MountLifecycleTests.swift" -o "${BIN}"

"${BIN}" "${TEMP_DIR}" "${PYTHON_PATH}" &
TEST_PID=$!
wait "${TEST_PID}"
