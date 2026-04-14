#!/usr/bin/env bash
# F3 · Fetch Markdown Viewer vendor JS files from their upstream URLs.
# Run ONLY when intentionally upgrading/reinitializing the vendor bundle.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="$REPO_ROOT/Resources/MarkdownViewer/vendor"
LOCK_FILE="$REPO_ROOT/Resources/MarkdownViewer/vendor.lock.json"

mkdir -p "$VENDOR_DIR"

PY="$(command -v python3 || command -v python)"
rows=$("$PY" - "$LOCK_FILE" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as fh:
    data = json.load(fh)
for name, info in data["dependencies"].items():
    print("{}\t{}\t{}".format(name, info["sourceUrl"], info["file"]))
PYEOF
)

while IFS=$'\t' read -r name url file; do
  [[ -z "$name" ]] && continue
  out="$VENDOR_DIR/$file"
  echo "fetching $name -> $out"
  curl -sSL -o "$out" "$url"
done <<< "$rows"

echo "Done. Run scripts/verify-markdown-viewer-vendor.sh to confirm integrity."
