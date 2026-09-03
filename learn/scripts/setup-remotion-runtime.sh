#!/usr/bin/env bash
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE_DIR="$SKILL_DIR/assets/remotion-runtime"
ARCHIVE_DIR="${LEARN_ARCHIVE_ROOT:-${HOME}/.claude/learn}"
RUNTIME_DIR="$ARCHIVE_DIR/.remotion"

mkdir -p "$RUNTIME_DIR/src/lib" "$RUNTIME_DIR/scripts" "$RUNTIME_DIR/public"

if [ ! -f "$RUNTIME_DIR/package.json" ]; then
  cp "$TEMPLATE_DIR/package.json" "$RUNTIME_DIR/package.json"
fi

install -m 755 "$TEMPLATE_DIR/build.sh" "$RUNTIME_DIR/build.sh"
install -m 755 "$TEMPLATE_DIR/remotion.sh" "$RUNTIME_DIR/remotion.sh"
install -m 755 "$TEMPLATE_DIR/qa-stills.sh" "$RUNTIME_DIR/qa-stills.sh"
install -m 644 "$TEMPLATE_DIR/src/lib/register.jsx" "$RUNTIME_DIR/src/lib/register.jsx"
install -m 644 "$TEMPLATE_DIR/src/lib/learn-asset.js" "$RUNTIME_DIR/src/lib/learn-asset.js"
install -m 644 "$TEMPLATE_DIR/src/lib/root.jsx" "$RUNTIME_DIR/src/lib/root.jsx"
install -m 644 "$TEMPLATE_DIR/scripts/prepare-cli.mjs" "$RUNTIME_DIR/scripts/prepare-cli.mjs"

cd "$RUNTIME_DIR"
npm install --no-audit --no-fund --save-exact \
  react@18.3.1 react-dom@18.3.1 remotion@4.0.516 \
  @remotion/player@4.0.516 @remotion/cli@4.0.516 @remotion/media@4.0.516 \
  @remotion/layout-utils@4.0.516 \
  esbuild@0.28.2

echo "learn Remotion 런타임 준비 완료: $RUNTIME_DIR"
