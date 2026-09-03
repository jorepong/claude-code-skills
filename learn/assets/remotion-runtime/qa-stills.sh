#!/usr/bin/env bash
set -euo pipefail

RUNTIME_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SLUG="${1:-}"
COMPOSITION="${2:-}"
OUTPUT_DIR="${3:-}"
shift $(( $# >= 3 ? 3 : $# ))

if [ -z "$SLUG" ] || [ -z "$COMPOSITION" ] || [ -z "$OUTPUT_DIR" ]; then
  cat >&2 <<'EOF'
사용법: qa-stills.sh <주제-슬러그> <컴포지션-ID> <출력-폴더> [추가-프레임...]

기본으로 첫 프레임·25%·50%·75%·마지막 프레임을 렌더합니다.
TIMELINE 프레임과 이동 요소가 가장 가까워지는 프레임은 추가 인자로 넘기세요.
EOF
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
COMPOSITIONS="$($RUNTIME_DIR/remotion.sh compositions "$SLUG" 2>&1)"
DURATION="$(printf '%s\n' "$COMPOSITIONS" | awk -v id="$COMPOSITION" \
  '$1 == id && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+x[0-9]+$/ && $4 ~ /^[0-9]+$/ {print $4; exit}')"

if [ -z "$DURATION" ]; then
  printf '%s\n' "$COMPOSITIONS" >&2
  echo "컴포지션을 찾거나 길이를 읽지 못했습니다: $COMPOSITION" >&2
  exit 1
fi

LAST=$((DURATION - 1))
FRAMES="0
$((LAST / 4))
$((LAST / 2))
$(((LAST * 3) / 4))
$LAST"
for frame in "$@"; do
  if [[ ! "$frame" =~ ^[0-9]+$ ]] || [ "$frame" -gt "$LAST" ]; then
    echo "범위를 벗어난 추가 프레임입니다: $frame (0~$LAST)" >&2
    exit 1
  fi
  FRAMES="$FRAMES
$frame"
done

COUNT=0
while IFS= read -r frame; do
  [ -n "$frame" ] || continue
  file="$OUTPUT_DIR/frame-$(printf '%06d' "$frame").png"
  "$RUNTIME_DIR/remotion.sh" still "$SLUG" "$COMPOSITION" "$file" --frame="$frame"
  COUNT=$((COUNT + 1))
done < <(printf '%s\n' "$FRAMES" | sort -nu)

if command -v ffmpeg >/dev/null 2>&1; then
  ROWS=$(((COUNT + 1) / 2))
  ffmpeg -y -loglevel error -pattern_type glob -i "$OUTPUT_DIR/frame-*.png" \
    -vf "scale=640:-2,tile=2x${ROWS}:padding=12:margin=12:color=0xfffdf9" \
    -frames:v 1 "$OUTPUT_DIR/contact-sheet.jpg"
  echo "QA 정지 화면 ${COUNT}개와 contact-sheet.jpg를 만들었습니다: $OUTPUT_DIR"
else
  echo "QA 정지 화면 ${COUNT}개를 만들었습니다: $OUTPUT_DIR"
fi
