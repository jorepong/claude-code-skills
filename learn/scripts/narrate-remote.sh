#!/usr/bin/env bash
# narrate-remote.sh — 낭독 렌더(narrate.sh)를 다른 맥에서 돌리고 결과를 가져온다.
#
# 사양이 낮은 기기에서 Qwen3-TTS를 직접 돌리지 않으려고 쓴다. 보통은 직접 부르지 않는다 —
# ~/.claude/learn/.render-host 파일에 SSH 호스트 이름(예: render-mac)이 있으면 narrate.sh가 이 스크립트로 넘긴다.
#
# 사용법:
#   narrate-remote.sh <호스트> <폴더>
#
# 순서: 접속 확인 → 이 기기의 렌더 코드(scripts/ · assets/tts/)를 원격 ~/.claude/learn/.remote-skill/로 복사 →
#       폴더를 원격 같은 경로로 복사 → 원격에서 그 복사본의 narrate.sh 실행(caffeinate로 잠들지 않게) →
#       audio/ · player.html을 포함한 폴더를 다시 가져온다.
# 렌더는 원격에 설치된 learn이 아니라 이 기기에서 보낸 코드로 하므로, 두 기기의 learn 판이 달라도 된다.
# 원격에 필요한 것은 음성 모델 환경(~/.claude/learn/.tts-venv-qwen-xvector — 없으면 첫 실행이 만든다) · ffmpeg · uv뿐이다.
# 원격에 접속할 수 없으면 이 기기에서 읽기용 player만 만들고(LEARN_TEXT_ONLY=1) 종료 코드 2로 끝난다 —
# 원격 맥이 켜진 뒤 narrate.sh <폴더>를 다시 실행하면 음성이 붙는다.
#
# 환경변수: LEARN_*로 시작하는 변수는 원격 narrate.sh에 그대로 넘긴다.
#   LEARN_REMOTE_CHECK 1이면 접속 확인만 하고 끝낸다.

set -euo pipefail

HOST="${1:-}"
DIR_IN="${2:-}"
if [ -z "$HOST" ] || [ -z "$DIR_IN" ]; then
  echo "사용법: narrate-remote.sh <호스트> <폴더>" >&2
  exit 1
fi
DIR="$(cd "$DIR_IN" && pwd)"
case "$DIR" in
  "$HOME"/*) REL="${DIR#"$HOME"/}" ;;
  *) echo "폴더가 홈 아래에 있어야 원격에서 같은 경로로 맞출 수 있습니다: $DIR" >&2; exit 1 ;;
esac
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=8 -o ServerAliveInterval=30 -o ServerAliveCountMax=6 "$HOST")

if ! "${SSH[@]}" true 2>/dev/null; then
  echo "원격 맥($HOST)에 접속할 수 없습니다 — 켜져 있고 잠들지 않았는지, Tailscale이 연결됐는지 확인하세요." >&2
  echo "지금은 이 기기에서 읽기용 player만 만듭니다. 음성은 원격 맥이 켜진 뒤 narrate.sh <폴더>를 다시 실행하면 붙습니다." >&2
  LEARN_TEXT_ONLY=1 LEARN_RENDER_LOCAL=1 bash "$SKILL_DIR/scripts/narrate.sh" "$DIR"
  exit 2
fi

[ "${LEARN_REMOTE_CHECK:-0}" = 1 ] && { echo "접속 확인 통과: $HOST"; exit 0; }

# 대본을 쓴 learn과 그 대본을 읽는 렌더 코드가 같은 판이어야 한다 — 이 기기의 렌더 코드를 보내 그것으로 렌더한다.
REMOTE_SKILL=".claude/learn/.remote-skill"
echo "[$HOST] 렌더 코드 보내는 중: ~/$REMOTE_SKILL"
"${SSH[@]}" "mkdir -p $REMOTE_SKILL/assets"
rsync -a --delete --exclude '__pycache__' -e "ssh -o BatchMode=yes" "$SKILL_DIR/scripts/" "$HOST:$REMOTE_SKILL/scripts/"
rsync -a --delete -e "ssh -o BatchMode=yes" "$SKILL_DIR/assets/tts/" "$HOST:$REMOTE_SKILL/assets/tts/"

ENV_ARGS=(LEARN_RENDER_LOCAL=1)
while IFS='=' read -r name _; do
  [ "$name" = LEARN_RENDER_LOCAL ] && continue
  ENV_ARGS+=("$name=${!name}")
done < <(env | grep -E '^LEARN_[A-Z0-9_]*=' || true)
# ssh로 바로 부르면 셸 설정이 안 읽혀 Homebrew(ffmpeg · uv) · nvm(node)이 PATH에 없다 — 로그인 셸로 감싸고 nvm을 불러온다.
# ssh 세션에는 LANG이 없어 bash가 한글이 붙은 변수 이름("$nn에")을 잘못 읽는다 — UTF-8 로캘을 지정한다.
INNER="export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 && cd ~ && { [ -s ~/.nvm/nvm.sh ] && . ~/.nvm/nvm.sh >/dev/null 2>&1 || true; } && env"
for kv in "${ENV_ARGS[@]}"; do INNER+=" $(printf '%q' "$kv")"; done
INNER+=" caffeinate -i bash ~/$REMOTE_SKILL/scripts/narrate.sh $(printf '%q' "$REL")"
REMOTE_CMD="zsh -lc $(printf '%q' "$INNER")"

echo "[$HOST] 폴더 보내는 중: ~/$REL"
"${SSH[@]}" "mkdir -p $(printf '%q' "$REL")"
rsync -a -e "ssh -o BatchMode=yes" "$DIR/" "$HOST:$REL/"

echo "[$HOST] 낭독 렌더 시작"
"${SSH[@]}" "$REMOTE_CMD"

echo "[$HOST] 결과 가져오는 중"
rsync -a -e "ssh -o BatchMode=yes" "$HOST:$REL/" "$DIR/"
echo "완료 — 음성과 player가 이 기기의 ${DIR}에 들어왔습니다."
