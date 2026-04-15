#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
DASH_ROOT="$REPO_ROOT/dash_web"
OUTPUT_ROOT="${1:-$REPO_ROOT/build/dash-assets}"

if ! command -v gleam >/dev/null 2>&1; then
  echo "gleam is required to build dashboard assets" >&2
  exit 1
fi

if [ ! -f "$DASH_ROOT/gleam.toml" ]; then
  echo "dash_web/gleam.toml is missing" >&2
  exit 1
fi

rm -rf "$OUTPUT_ROOT"
mkdir -p "$OUTPUT_ROOT/app"

(
  cd "$DASH_ROOT"
  gleam build --target javascript
)

cp -R "$DASH_ROOT/build/dev/javascript/." "$OUTPUT_ROOT/app/"
cp "$DASH_ROOT/static/dash.css" "$OUTPUT_ROOT/dash.css"

cat > "$OUTPUT_ROOT/dash.js" <<'EOF'
import { main } from "./app/dash_web/dash_web.mjs";

main();
EOF

echo "Built dashboard assets in $OUTPUT_ROOT"
