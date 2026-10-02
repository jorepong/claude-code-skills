#!/usr/bin/env bash
# qa-svg.sh — 문서 폴더의 정적 SVG를 플레이어 본문 폭으로 렌더해 눈으로 검사할 PNG를 만든다.
#
# 왜 필요한가: 손으로 그린 SVG는 원본 좌표계에서는 멀쩡해 보여도 player.html의 본문 폭
# (약 800px)으로 축소되면 글자가 겹치거나 잘린다(실제 산출물에서 제목 행 겹침이 관찰됐다).
# 애니메이션은 qa-stills.sh가 정지 화면을 뽑지만 정적 SVG에는 그 단계가 없었다.
# 이 스크립트가 만든 PNG를 Read 도구로 직접 보고, 겹침·잘림·14px 미만 글자를 고친다.
#
# 사용법: qa-svg.sh <문서 폴더> [출력 폴더]
#   기본 출력: <문서 폴더>/.qa-svg/<이름>.png  (산출물이 아니므로 숨김 폴더)

set -euo pipefail

FOLDER="${1:-}"
[ -n "$FOLDER" ] && [ -d "$FOLDER" ] || { echo "사용법: qa-svg.sh <문서 폴더> [출력 폴더]" >&2; exit 1; }
FOLDER="$(cd "$FOLDER" && pwd)"
OUT="${2:-$FOLDER/.qa-svg}"
WIDTH="${LEARN_QA_SVG_WIDTH:-800}"   # player.html 기본 본문 폭에 맞춘 값

shopt -s nullglob
svgs=( "$FOLDER"/assets/*.svg )
[ ${#svgs[@]} -gt 0 ] || { echo "assets/*.svg 가 없습니다: $FOLDER" >&2; exit 0; }
mkdir -p "$OUT"

CHROME=""
for c in "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
         "/Applications/Chromium.app/Contents/MacOS/Chromium" \
         "$(command -v google-chrome || true)" "$(command -v chromium || true)"; do
  [ -n "$c" ] && [ -x "$c" ] && { CHROME="$c"; break; }
done

render_one() {
  local svg="$1" png="$2"
  # viewBox 비율로 높이를 구해 본문 폭에 맞춘 캔버스를 만든다(없으면 width/height 속성).
  local dims
  dims="$(python3 - "$svg" "$WIDTH" <<'PY'
import re,sys
s=open(sys.argv[1],encoding='utf-8',errors='ignore').read(2000); W=int(sys.argv[2])
m=re.search(r'viewBox="\s*[\d.\-]+[ ,]+[\d.\-]+[ ,]+([\d.]+)[ ,]+([\d.]+)',s)
if not m: m=re.search(r'width="([\d.]+)[^"]*"[^>]*height="([\d.]+)',s)
w,h=(float(m.group(1)),float(m.group(2))) if m else (1200.0,600.0)
print(W, max(80,int(round(W*h/w))+2))
PY
)"
  local w h; read -r w h <<<"$dims"
  if [ -n "$CHROME" ]; then
    local html="$OUT/.$(basename "$svg").html"
    # 플레이어와 같은 종이색 배경·본문 폭 안에 SVG를 100%로 넣어, 실제 임베드 크기로 축소한다.
    printf '<!doctype html><meta charset="utf-8"><body style="margin:0;background:#fffdf9"><img src="file://%s" style="display:block;width:%spx;height:auto"></body>' "$svg" "$w" > "$html"
    "$CHROME" --headless=new --disable-gpu --hide-scrollbars --window-size="${w},${h}" \
      --screenshot="$png" "file://$html" >/dev/null 2>&1 || return 1
    rm -f "$html"
  elif command -v rsvg-convert >/dev/null; then
    rsvg-convert -w "$w" -b '#fffdf9' "$svg" -o "$png" || return 1
  else
    echo "Chrome 또는 rsvg-convert가 필요합니다." >&2; return 1
  fi
}

n=0
for svg in "${svgs[@]}"; do
  name="$(basename "${svg%.svg}")"
  png="$OUT/$name.png"
  if render_one "$svg" "$png"; then n=$((n+1)); echo "  $png"; else echo "  ✗ 렌더 실패: $svg" >&2; fi
done
echo "SVG ${n}개를 본문 폭 ${WIDTH}px로 렌더했습니다 → $OUT"
echo "각 PNG를 Read 도구로 열어 글자 겹침·잘림·너무 작은 글자(14px 상당 미만)를 확인하세요. 포스터(.anim/.sim)는 정지 구도만 봅니다."
