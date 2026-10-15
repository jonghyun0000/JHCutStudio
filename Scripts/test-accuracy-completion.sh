#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 -B Tests/AccuracyCompletionTests.py --output "${1:?Supply a fresh output directory}"
