#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "Running release pre-tag checks..."
"$ROOT_DIR/tests/test_ci_sparkle_build_monotonic.sh"
"$ROOT_DIR/scripts/verify-markdown-viewer-vendor.sh"
echo "Release pre-tag checks passed."
