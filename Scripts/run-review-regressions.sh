#!/usr/bin/env bash
# Offline real-source review regressions; no user mounts, OAuth, or Keychain.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
export DRIVESTREAM_TEST_PYTHON="$(command -v "${PYTHON:-python3}")"
[[ "${DRIVESTREAM_TEST_PYTHON}" = /* ]] || { printf 'python3 is required.\n' >&2; exit 1; }
export DRIVESTREAM_SERVICE_TEST_SOURCE="${ROOT}/Scripts/ReviewRegressionTests.swift"
bash "${ROOT}/Scripts/run-service-tests.sh"
