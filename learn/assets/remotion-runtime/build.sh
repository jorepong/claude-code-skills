#!/usr/bin/env bash
set -euo pipefail

RUNTIME_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SLUG="${1:-}"
OUT="${2:-}"

if [ -z "$SLUG" ] || [ -z "$OUT" ]; then
  echo "사용법: build.sh <주제-슬러그> <문서-폴더>" >&2
  exit 1
fi

if [[ ! "$SLUG" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
  echo "잘못된 주제 슬러그: $SLUG" >&2
  exit 1
fi

ENTRY="$RUNTIME_DIR/src/$SLUG/index.jsx"
if [ ! -f "$ENTRY" ]; then
  echo "진입점 없음: $ENTRY" >&2
  exit 1
fi

mkdir -p "$OUT/assets"
"$RUNTIME_DIR/node_modules/.bin/esbuild" "$ENTRY" \
  --bundle --format=iife --minify \
  --define:process.env.NODE_ENV='"production"' \
  --outfile="$OUT/assets/anim.bundle.js"

PUBLIC_TOPIC="$RUNTIME_DIR/public/$SLUG"
if [ -d "$PUBLIC_TOPIC" ]; then
  mkdir -p "$OUT/assets/$SLUG"
  cp -R "$PUBLIC_TOPIC/." "$OUT/assets/$SLUG/"
fi
