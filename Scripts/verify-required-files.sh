#!/usr/bin/env bash
# Keep the original repository names and enforce the modernized runtime contract.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
python3 "${ROOT}/Scripts/verify_repository.py"
