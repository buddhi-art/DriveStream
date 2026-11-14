#!/usr/bin/env bash
# Test display coordinator ordering using only private dynamic RC fixtures.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
PYTHON="${PYTHON:-python3}"
if ! command -v "${PYTHON}" >/dev/null 2>&1; then
  echo "python3 is required for the RC integration test" >&2
  exit 1
fi

TEMP_PARENT="$("${PYTHON}" -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "${TMPDIR:-/tmp}")"
TEMP_DIR="$(mktemp -d "${TEMP_PARENT:?}/drivestream-telemetry-test.XXXXXX")"
SERVER_PID=""
cleanup() {
  local status=$?
  trap - EXIT INT TERM
  if [[ -n "${SERVER_PID}" ]]; then
    # Only signal a still-running child of this script, never a reused PID or
    # another rclone/python process. No process-name or process-group killing.
    local child
    for child in $(jobs -pr); do
      if [[ "${child}" == "${SERVER_PID}" ]]; then
        kill "${SERVER_PID}" 2>/dev/null || true
      fi
    done
    wait "${SERVER_PID}" 2>/dev/null || true
  fi
  local resolved
  resolved="$("${PYTHON}" -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "${TEMP_DIR:?}")"
  # Verify the exact resolved absolute target immediately before deleting it.
  case "${TEMP_DIR:?}" in
    "${TEMP_PARENT:?}"/drivestream-telemetry-test.*)
      if [[ "${resolved}" == "${TEMP_DIR}" && -d "${TEMP_DIR}" && ! -L "${TEMP_DIR}" ]]; then
        rm -rf -- "${TEMP_DIR:?}"
      else
        echo "Refusing to clean unexpected temporary path: ${TEMP_DIR}" >&2
      fi
      ;;
    *) echo "Refusing to clean unexpected temporary path: ${TEMP_DIR}" >&2 ;;
  esac
  exit "${status}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

show_server_log() {
  "${PYTHON}" -c 'import pathlib,sys; sys.stderr.write(pathlib.Path(sys.argv[1]).read_text())' "${TEMP_DIR:?}/server.log"
}

# Mock owns both sockets from bind(port=0) until shutdown. The readiness marker
# is published only after the full address manifest is flushed and closed.
"${PYTHON}" "${ROOT}/Scripts/MockRcloneRC.py" \
  --address-file "${TEMP_DIR}/addresses.json" --ready-file "${TEMP_DIR}/ready" \
  >"${TEMP_DIR}/server.log" 2>&1 &
SERVER_PID=$!
for ((attempt = 0; attempt < 100; attempt++)); do
  if [[ -s "${TEMP_DIR}/ready" ]]; then
    break
  fi
  if ! kill -0 "${SERVER_PID}" 2>/dev/null; then
    echo "Mock rclone RC server failed to start:" >&2
    show_server_log
    exit 1
  fi
  sleep 0.05
done
if [[ ! -s "${TEMP_DIR}/ready" ]]; then
  echo "Timed out waiting for the mock rclone RC server" >&2
  show_server_log
  exit 1
fi

ARCH="$(uname -m)"
case "${ARCH}" in
  arm64|x86_64) SWIFT_ARCH="${ARCH}" ;;
  *) echo "Unsupported architecture: ${ARCH}" >&2; exit 1 ;;
esac
mkdir -p "${TEMP_DIR}/module-cache"
BIN="${TEMP_DIR}/TelemetryCoordinatorTests"
SWIFT_FLAGS=(-parse-as-library -swift-version 6 -strict-concurrency=complete -warnings-as-errors)
if [[ "${TELEMETRY_TEST_TSAN:-0}" == "1" ]]; then
  SWIFT_FLAGS+=(-sanitize=thread)
fi
xcrun swiftc "${SWIFT_FLAGS[@]}" \
  -target "${SWIFT_ARCH}-apple-macosx14.0" \
  -module-cache-path "${TEMP_DIR}/module-cache" \
  "${ROOT}/Sources/Models/RCStatsModels.swift" \
  "${ROOT}/Sources/Models/UploadSafety.swift" \
  "${ROOT}/Sources/Services/RcloneRCClient.swift" \
  "${ROOT}/Sources/Services/TelemetryService.swift" \
  "${ROOT}/Sources/Services/MountTelemetryCoordinator.swift" \
  "${ROOT}/Scripts/TelemetryCoordinatorTests.swift" \
  -o "${BIN}"

if ! "${BIN}" "${TEMP_DIR}/addresses.json"; then
  show_server_log
  exit 1
fi
