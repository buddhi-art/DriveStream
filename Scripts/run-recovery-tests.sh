#!/usr/bin/env bash
# Strict real-source recovery tests; only loopback/private fixtures are used.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
PYTHON="${PYTHON:-python3}"
if ! command -v "${PYTHON}" >/dev/null 2>&1; then
  echo "python3 is required for recovery fixtures" >&2
  exit 1
fi
PYTHON_PATH="$(command -v "${PYTHON}")"
# StreamConfig intentionally rejects /private/var mount paths. /tmp still resolves
# to a freshly created private directory, checked again immediately at cleanup.
TEMP_DIR="$(mktemp -d /tmp/drivestream-recovery.XXXXXX)"
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
    # Verify event parent plus current private helper command immediately before
    # every signal; a stale/reused/unrelated PID is never cleanup authority.
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
    if not isinstance(pid, int) or pid <= 1 or not is_owned(pid):
        continue
    try:
        os.kill(pid, signal.SIGTERM)
        deadline = time.monotonic() + 1
        while time.monotonic() < deadline and is_owned(pid):
            time.sleep(0.02)
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
  case "${TEMP_DIR:?}" in
    /tmp/drivestream-recovery.*)
      if [[ "${resolved}" == "${EXPECTED_REAL:?}" && -d "${TEMP_DIR}" && ! -L "${TEMP_DIR}" ]]; then
        rm -rf -- "${TEMP_DIR:?}"
      else
        echo "Refusing unexpected recovery temporary path: ${TEMP_DIR}" >&2
      fi
      ;;
    *) echo "Refusing unexpected recovery temporary path: ${TEMP_DIR}" >&2 ;;
  esac
  exit "${status}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

BUILD="${TEMP_DIR}/build"
mkdir -p "${BUILD}/module-cache"
# Snapshot ALL source inputs before compiling: parallel work cannot mutate an
# in-flight compiler's inputs. Reuse only the existing private fixture prefix;
# its @main and existing tests are neither compiled nor changed by this runner.
"${PYTHON_PATH}" - "${ROOT}" "${BUILD}" <<'PY'
import shutil, sys
from pathlib import Path
root, build = map(Path, sys.argv[1:])
shutil.copytree(root / "Sources", build / "Sources")
shutil.copyfile(root / "Scripts/MountLifecycleTests.swift", build / "MountLifecycleTests.swift")
shutil.copyfile(root / "Scripts/RecoveryRegressionTests.swift", build / "RecoveryRegressionTests.swift")
fixture = (build / "MountLifecycleTests.swift").read_text()
marker = "\n@main\n"
assert fixture.count(marker) == 1, "Expected exactly one lifecycle test entrypoint"
prefix = fixture.split(marker, 1)[0]
(build / "RecoveryTestsInput.swift").write_text(prefix + "\n" + (build / "RecoveryRegressionTests.swift").read_text())
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
    if [[ "${source##*/}" != "DriveStreamApp.swift" ]]; then
      SOURCES+=("${source}")
    fi
  done
done
FLAGS=(-parse-as-library -swift-version 6 -strict-concurrency=complete -warnings-as-errors)
if [[ "${RECOVERY_TEST_TSAN:-0}" == "1" ]]; then
  FLAGS+=(-sanitize=thread)
fi
BIN="${BUILD}/RecoveryRegressionTests"
printf 'Compile %s real source files with Swift 6/macOS14, complete strict concurrency, warnings as errors, SDK: %s\n' "${#SOURCES[@]}" "${SDK}"
xcrun swiftc "${FLAGS[@]}" -sdk "${SDK}" -target "${ARCH}-apple-macosx14.0" \
  -module-cache-path "${BUILD}/module-cache" "${SOURCES[@]}" \
  "${BUILD}/RecoveryTestsInput.swift" -o "${BIN}"

"${BIN}" "${TEMP_DIR}" "${PYTHON_PATH}" &
TEST_PID=$!
wait "${TEST_PID}"
