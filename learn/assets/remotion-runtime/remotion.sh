#!/usr/bin/env bash
set -euo pipefail

RUNTIME_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTION_BIN="$RUNTIME_DIR/node_modules/.bin/remotion"

usage() {
  cat >&2 <<'EOF'
사용법:
  remotion.sh compositions <주제-슬러그> [옵션]
  remotion.sh studio <주제-슬러그> [옵션]
  remotion.sh still <주제-슬러그> <컴포지션-ID> <출력.png> [옵션]
  remotion.sh render <주제-슬러그> <컴포지션-ID> <출력.mp4> [옵션]
  remotion.sh add <패키지> [패키지...]
  remotion.sh versions
EOF
  exit 1
}

if [ ! -x "$REMOTION_BIN" ]; then
  echo "Remotion CLI가 없습니다. setup-remotion-runtime.sh를 먼저 실행하세요." >&2
  exit 1
fi

COMMAND="${1:-}"
case "$COMMAND" in
  add)
    shift
    [ "$#" -gt 0 ] || usage
    cd "$RUNTIME_DIR"
    exec "$REMOTION_BIN" add "$@"
    ;;
  versions)
    cd "$RUNTIME_DIR"
    exec "$REMOTION_BIN" versions
    ;;
  compositions|studio)
    SLUG="${2:-}"
    [ -n "$SLUG" ] || usage
    shift 2
    ENTRY="$(node "$RUNTIME_DIR/scripts/prepare-cli.mjs" "$SLUG")"
    cd "$RUNTIME_DIR"
    if [ "$COMMAND" = "studio" ]; then
      exec "$REMOTION_BIN" studio "$ENTRY" --no-open "$@"
    fi
    exec "$REMOTION_BIN" compositions "$ENTRY" "$@"
    ;;
  still|render)
    SLUG="${2:-}"
    COMPOSITION="${3:-}"
    OUTPUT="${4:-}"
    [ -n "$SLUG" ] && [ -n "$COMPOSITION" ] && [ -n "$OUTPUT" ] || usage
    shift 4
    ENTRY="$(node "$RUNTIME_DIR/scripts/prepare-cli.mjs" "$SLUG")"
    cd "$RUNTIME_DIR"
    exec "$REMOTION_BIN" "$COMMAND" "$ENTRY" "$COMPOSITION" "$OUTPUT" "$@"
    ;;
  *)
    usage
    ;;
esac
