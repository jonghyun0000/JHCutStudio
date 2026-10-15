#!/bin/bash
# Build current code and preserve separate evidence on every run.
set -euo pipefail
cd "$(dirname "$0")/.."
exec python3 Scripts/verification-run.py "$@"
