#!/usr/bin/env bash
# F3 · Verify Markdown Viewer vendor JS integrity against vendor.lock.json.
# Exit 0 if all hashes match; exit 1 on any mismatch / missing file.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="$REPO_ROOT/Resources/MarkdownViewer/vendor"
LOCK_FILE="$REPO_ROOT/Resources/MarkdownViewer/vendor.lock.json"

if [[ ! -d "$VENDOR_DIR" ]]; then
  echo "ERROR: vendor dir missing: $VENDOR_DIR" >&2
  exit 1
fi
if [[ ! -f "$LOCK_FILE" ]]; then
  echo "ERROR: lock file missing: $LOCK_FILE" >&2
  exit 1
fi

PY="$(command -v python3 || command -v python || true)"
if [[ -z "$PY" ]]; then
  echo "ERROR: python3 required to parse vendor.lock.json" >&2
  exit 1
fi

rows=$("$PY" - "$LOCK_FILE" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as fh:
    data = json.load(fh)
for name, info in data["dependencies"].items():
    print("{}\t{}\t{}".format(name, info["sha256"], info["file"]))
PYEOF
)

failures=0
while IFS=$'\t' read -r name expected file; do
  [[ -z "$name" ]] && continue
  path="$VENDOR_DIR/$file"
  if [[ ! -f "$path" ]]; then
    echo "MISSING $name: $path" >&2
    failures=$((failures + 1))
    continue
  fi
  actual=$(shasum -a 256 "$path" | awk '{print $1}')
  if [[ "$actual" != "$expected" ]]; then
    echo "MISMATCH $name" >&2
    echo "  expected: $expected" >&2
    echo "  actual:   $actual" >&2
    echo "  file:     $path" >&2
    failures=$((failures + 1))
  else
    echo "OK $name ($file)"
  fi
done <<< "$rows"

if (( failures > 0 )); then
  echo "FAIL: $failures vendor file(s) failed integrity check" >&2
  exit 1
fi

echo "All vendor files verified."
