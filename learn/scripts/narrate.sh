#!/usr/bin/env bash
# narrate.sh — learn 스킬 낭독 렌더러
#
# 한 폴더 안의 낭독 스크립트(*.script.md)를 문단 단위로 음성(mp3)으로 렌더하고,
# 학습 문서를 읽으며 그 음성을 한자리에서 제어하는 player.html을 생성한다.
# 문단마다 따로 렌더해 길이를 재므로, "몇 초에 어느 문단"이라는 큐(cue)를 만들어
# player가 재생 위치에 맞춰 문서의 해당 블록을 하이라이트한다.
#
# 사용법:
#   narrate.sh <폴더>
#
# 환경변수:
#   LEARN_TTS_ENGINE  qwen(기본) | edge | say
#     edge — Microsoft edge-tts(무료·키 불필요, 빠름). 사용자가 명시적으로 요청할 때만 선택.
#     qwen — 로컬 Qwen3-TTS(MLX), 내장 참조 음성의 x-vector 클로닝.
#     say  — macOS 내장(오프라인, 품질 낮음). 사용자가 명시적으로 요청할 때만 선택.
#   LEARN_ALLOW_ALTERNATE_TTS 1이어야 edge·say 선택을 허용한다.
#   LEARN_REUSE_AUDIO 1이면 기존 audio/NN.mp3·NN.cues.json을 보존한 채 player만 다시 만든다.
#   LEARN_TEXT_ONLY 1이면 TTS를 실행하지 않고 현재 챕터 메뉴가 든 읽기용 player만 만든다.
#   LEARN_TTS_VOICE   음성 이름. 기본: edge=ko-KR-SunHiNeural, say=Yuna. (qwen은 아래 클론 목소리 사용)
#   LEARN_TTS_VOICE_NAME qwen 클론 목소리를 이름으로 선택. 내장 assets/tts/<이름>을 먼저 찾고, 없으면 ~/.claude/learn/.voices/<이름>.
#   LEARN_TTS_VOICE_DIR  목소리 폴더를 경로로 직접 지정(이름보다 우선). 안에 reference.wav + reference.txt 가 목소리의 실체.
#   LEARN_QWEN_BATCH_SIZE x-vector 텐서 배치 최대 크기. 기본 16. 32는 더 빠르지만 tail-latency 증가 가능.
#   LEARN_QWEN_CHUNK_CHARS 긴 문장의 내부 분할 상한. 기본 240자(완성 뒤 한 문단 WAV로 재결합).
#   LEARN_QWEN_BATCH_AUDIO_TOKEN_BUDGET 예상 음성 토큰 기준 배치 패딩 예산. 기본 4000.
#   LEARN_QWEN_TOKEN_FACTOR 텍스트 토큰 대비 허용할 음성 토큰 배수. 기본 4.0.
#   LEARN_QWEN_TOP_K 샘플링 후보 토큰 수. 기본 50.
#   LEARN_QWEN_TOP_P 누적 확률 샘플링 상한. 기본 1.0.
#   LEARN_QWEN_REPETITION_PENALTY 반복 토큰 패널티. 기본 1.05.
#   LEARN_QWEN_MAX_TOKEN_RUN 동일 주 코덱 토큰 연속 허용 횟수. 기본 16(초과 시 해당 조각만 재시도).
#   LEARN_QWEN_MIN_VOICED_SECONDS 유효 발화로 인정할 최소 활성 구간. 기본 0.20초.
#   LEARN_QWEN_MIN_VOICED_RATIO 유효 발화로 인정할 최소 활성 프레임 비율. 기본 0.03.
#   LEARN_QWEN_EOS_DEFER_TOKENS 최초 codec EOS를 지정 프레임만큼 한 번 유예. 기본 0(실험 기능 비활성).
#   LEARN_QWEN_SILENCE_CAP 과도한 앞뒤·내부 무음 축소. 기본 1(활성), 0이면 파형 절단 비활성.
#
# 엔진 교체 지점은 render_chunk() 하나다. 다른 클라우드/로컬 TTS로 바꾸려면 여기만 고친다.

set -euo pipefail

ENGINE="${LEARN_TTS_ENGINE:-qwen}"
REUSE_AUDIO="${LEARN_REUSE_AUDIO:-0}"
TEXT_ONLY="${LEARN_TEXT_ONLY:-0}"
[ "$REUSE_AUDIO" = 1 ] && [ "$TEXT_ONLY" = 1 ] && {
  echo "LEARN_REUSE_AUDIO와 LEARN_TEXT_ONLY는 함께 사용할 수 없습니다." >&2
  exit 1
}
NEEDS_TTS=1
if [ "$REUSE_AUDIO" = 1 ] || [ "$TEXT_ONLY" = 1 ]; then NEEDS_TTS=0; fi
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MARKED="$SKILL_DIR/scripts/vendor/marked.min.js"
# TTS 환경은 스킬 코드 밖(데이터 영역)에 두어 스킬을 가볍고 이식 가능하게 유지한다. 없으면 아래에서 자동 생성.
TTS_VENV="$HOME/.claude/learn/.tts-venv"
EDGE_BIN="$TTS_VENV/bin/edge-tts"
# qwen(클로닝 낭독) 설정 — 생성 환경은 캐시하고 참조 목소리는 스킬에 내장한다.
QWEN_VENV="${LEARN_QWEN_VENV:-$HOME/.claude/learn/.tts-venv-qwen-xvector}"
QWEN_PY="$QWEN_VENV/bin/python"
QWEN_MODEL="${LEARN_QWEN_MODEL:-mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit}"
QWEN_REQUIRED_MLX_AUDIO="0.5.0"
BUILTIN_VOICES_ROOT="$SKILL_DIR/assets/tts"
EXTERNAL_VOICES_ROOT="$HOME/.claude/learn/.voices"
DEFAULT_QWEN_VOICE_NAME="interviewee-en-34s"
# 목소리 선택 우선순위: 경로 직접지정(DIR) > 이름(NAME: 내장 우선, 외부 폴백) > 기본 내장 참조
if [ -n "${LEARN_TTS_VOICE_DIR:-}" ]; then
  QWEN_VOICE_DIR="$LEARN_TTS_VOICE_DIR"
elif [ -n "${LEARN_TTS_VOICE_NAME:-}" ]; then
  if [ -d "$BUILTIN_VOICES_ROOT/$LEARN_TTS_VOICE_NAME" ]; then
    QWEN_VOICE_DIR="$BUILTIN_VOICES_ROOT/$LEARN_TTS_VOICE_NAME"
  else
    QWEN_VOICE_DIR="$EXTERNAL_VOICES_ROOT/$LEARN_TTS_VOICE_NAME"
  fi
else
  QWEN_VOICE_DIR="$BUILTIN_VOICES_ROOT/$DEFAULT_QWEN_VOICE_NAME"
fi
QWEN_REF_AUDIO="$QWEN_VOICE_DIR/reference.wav"
QWEN_REF_TEXT_FILE="$QWEN_VOICE_DIR/reference.txt"

case "$ENGINE" in
  qwen) VOICE="clone:$(basename "$QWEN_VOICE_DIR")" ;;
  edge) VOICE="${LEARN_TTS_VOICE:-ko-KR-SunHiNeural}" ;;
  say)  VOICE="${LEARN_TTS_VOICE:-Yuna}" ;;
  *) echo "알 수 없는 LEARN_TTS_ENGINE: $ENGINE (qwen|edge|say)" >&2; exit 1 ;;
esac
if [ "$NEEDS_TTS" = 1 ] && [ "$ENGINE" != qwen ] && [ "${LEARN_ALLOW_ALTERNATE_TTS:-0}" != 1 ]; then
  echo "edge·say 음성은 사용자가 명시적으로 요청한 경우에만 LEARN_ALLOW_ALTERNATE_TTS=1과 함께 선택할 수 있습니다." >&2
  exit 1
fi

FOLDER="${1:-}"
[ -z "$FOLDER" ] && { echo "사용법: narrate.sh <폴더>" >&2; exit 1; }
[ -d "$FOLDER" ] || { echo "폴더가 없습니다: $FOLDER" >&2; exit 1; }
FOLDER="$(cd "$FOLDER" && pwd)"

if [ "$NEEDS_TTS" = 1 ]; then
  command -v ffmpeg  >/dev/null || { echo "ffmpeg 필요: brew install ffmpeg" >&2; exit 1; }
  command -v ffprobe >/dev/null || { echo "ffprobe 필요(보통 ffmpeg에 포함)" >&2; exit 1; }
fi
command -v python3 >/dev/null || { echo "python3 필요." >&2; exit 1; }
[ -f "$MARKED" ] || { echo "렌더러 없음: $MARKED" >&2; exit 1; }
if [ "$NEEDS_TTS" = 1 ] && [ "$ENGINE" = edge ] && [ ! -x "$EDGE_BIN" ]; then
  echo "낭독 TTS(edge-tts)를 처음이라 설치합니다 → $TTS_VENV (한 번만)" >&2
  python3 -m venv "$TTS_VENV" >/dev/null 2>&1 && "$TTS_VENV/bin/pip" install -q --disable-pip-version-check edge-tts >/dev/null 2>&1 \
    || { echo "edge-tts 자동 설치 실패. 수동: python3 -m venv \"$TTS_VENV\" && \"$TTS_VENV/bin/pip\" install edge-tts" >&2; exit 1; }
fi
if [ "$NEEDS_TTS" = 1 ] && [ "$ENGINE" = say ]; then command -v say >/dev/null || { echo "say 없음(macOS 필요)" >&2; exit 1; }; fi
if [ "$NEEDS_TTS" = 1 ] && [ "$ENGINE" = qwen ]; then
  qwen_env_ready() {
    [ -x "$QWEN_PY" ] && "$QWEN_PY" -c \
      "import importlib.metadata as m; assert m.version('mlx-audio') == '$QWEN_REQUIRED_MLX_AUDIO'" \
      >/dev/null 2>&1
  }
  if ! qwen_env_ready; then
    echo "Qwen x-vector 환경을 준비합니다 → $QWEN_VENV (최초 1회)" >&2
    if command -v uv >/dev/null; then
      [ -x "$QWEN_PY" ] || uv venv --python 3.11 "$QWEN_VENV" >/dev/null
      uv pip install --python "$QWEN_PY" "mlx-audio==$QWEN_REQUIRED_MLX_AUDIO" >/dev/null
    else
      BOOTSTRAP_PY="$(command -v python3.11 || command -v python3)"
      [ -n "$BOOTSTRAP_PY" ] || { echo "Python 3 필요" >&2; exit 1; }
      [ -x "$QWEN_PY" ] || "$BOOTSTRAP_PY" -m venv "$QWEN_VENV"
      "$QWEN_PY" -m pip install -q "mlx-audio==$QWEN_REQUIRED_MLX_AUDIO"
    fi
  fi
  qwen_env_ready || { echo "Qwen TTS 환경 구성 실패: $QWEN_VENV" >&2; exit 1; }
  "$QWEN_PY" "$SKILL_DIR/scripts/patch_mlx_audio_xvector_batch.py" \
    || { echo "MLX-Audio x-vector 배치 호환 패치 실패" >&2; exit 1; }
  [ -f "$QWEN_REF_AUDIO" ] || { echo "클론 목소리 참조 오디오 없음: $QWEN_REF_AUDIO" >&2; exit 1; }
  [ -f "$QWEN_REF_TEXT_FILE" ] || { echo "클론 목소리 참조 대본 없음: $QWEN_REF_TEXT_FILE" >&2; exit 1; }
  echo "낭독 엔진: qwen x-vector(참조 $(basename "$QWEN_VOICE_DIR"), 전체 조각 디코드/최대 배치 ${LEARN_QWEN_BATCH_SIZE:-16}, 내부 분할 ${LEARN_QWEN_CHUNK_CHARS:-240}자, 0.6B 8bit 가중치)" >&2
fi

cd "$FOLDER"
shopt -s nullglob
scripts=( *.script.md )
[ ${#scripts[@]} -eq 0 ] && { echo "이 폴더에 *.script.md 가 없습니다: $FOLDER" >&2; exit 1; }

# 접두사는 audio/NN.*의 식별자이므로 중복이나 잘못된 이름을 렌더 전에 막는다.
prefixes=()
for sf in "${scripts[@]}"; do
  if [[ ! "$sf" =~ ^([0-9]+)-.+\.script\.md$ ]]; then
    echo "스크립트 파일명은 NN-이름.script.md 형식이어야 합니다: $sf" >&2
    exit 1
  fi
  nn="${BASH_REMATCH[1]}"
  for seen in "${prefixes[@]:-}"; do
    [ "$seen" = "$nn" ] && { echo "중복 스크립트 접두사: $nn" >&2; exit 1; }
  done
  prefixes+=("$nn")
  docs=( "$nn"-*.md )
  doc_count=0
  for doc in "${docs[@]}"; do
    [[ "$doc" == *.script.md ]] || doc_count=$((doc_count+1))
  done
  [ "$doc_count" -eq 1 ] || {
    echo "접두사 $nn에 대응하는 학습 문서는 정확히 하나여야 합니다(현재 $doc_count개)." >&2
    exit 1
  }
done

lock_dir="$FOLDER/.narrate.lock"
if ! mkdir "$lock_dir" 2>/dev/null; then
  lock_pid="$(sed -n '1p' "$lock_dir/pid" 2>/dev/null || true)"
  if [[ "$lock_pid" =~ ^[0-9]+$ ]] && ps -p "$lock_pid" -o pid= >/dev/null 2>&1; then
    echo "같은 폴더의 낭독 렌더가 이미 실행 중입니다(PID $lock_pid): $FOLDER" >&2
    exit 1
  fi
  if [[ ! "$lock_pid" =~ ^[0-9]+$ ]]; then
    echo "소유자를 확인할 수 없는 낭독 렌더 잠금이 있습니다: $lock_dir" >&2
    exit 1
  fi
  rm -f -- "$lock_dir/pid"
  rmdir "$lock_dir" 2>/dev/null || {
    echo "이전 렌더 잠금을 안전하게 회수하지 못했습니다: $lock_dir" >&2
    exit 1
  }
  mkdir "$lock_dir" 2>/dev/null || {
    echo "낭독 렌더 잠금 획득에 실패했습니다: $FOLDER" >&2
    exit 1
  }
fi
printf '%s\n' "$$" > "$lock_dir/pid"
tmp=""
stage=""
old_audio=""
cleanup() {
  if [ -n "$old_audio" ] && [ -d "$old_audio" ] && [ ! -e "$FOLDER/audio" ]; then
    mv "$old_audio" "$FOLDER/audio" 2>/dev/null || true
  fi
  [ -z "$tmp" ] || rm -rf -- "$tmp"
  [ -z "$stage" ] || rm -rf -- "$stage"
  rm -f -- "$lock_dir/pid"
  rmdir "$lock_dir" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
tmp="$(mktemp -d)"
stage="$(mktemp -d "$FOLDER/.narrate-stage.XXXXXX")"
mkdir -p "$stage/audio"

# --- 엔진 교체 지점: 텍스트파일 → PCM WAV(한 문단) ---
render_chunk() {
  local infile="$1" outwav="$2"
  if [ "$ENGINE" = qwen ]; then
    # qwen은 폴더 전체를 한 모델 로드와 배치 큐로 사전 렌더한 상태다.
    # 여기서는 미리 만들어 둔 pNNN.wav의 포맷만 통일한다.
    local w="${infile%.txt}.wav"
    [ -f "$w" ] || { echo "qwen 사전 렌더 wav 없음: $w" >&2; return 1; }
    ffmpeg -y -loglevel error -i "$w" -ar 24000 -ac 1 -c:a pcm_f32le "$outwav"
  elif [ "$ENGINE" = edge ]; then
    local edge_mp3="${outwav%.wav}.edge.mp3"
    "$EDGE_BIN" --voice "$VOICE" --file "$infile" --write-media "$edge_mp3" >/dev/null 2>&1
    ffmpeg -y -loglevel error -i "$edge_mp3" -ar 24000 -ac 1 -c:a pcm_f32le "$outwav"
  else
    local aiff="${outwav%.wav}.aiff"
    say -v "$VOICE" -o "$aiff" -f "$infile"
    ffmpeg -y -loglevel error -i "$aiff" -ar 24000 -ac 1 -c:a pcm_f32le "$outwav"
  fi
}

if [ "$TEXT_ONLY" = 1 ]; then
  # 음성 렌더를 기다리지 않고도 stage 마커·숫자 발음 표기 같은 낭독 원문
  # 오류를 바로 잡는다. 생성물은 임시 폴더에만 만들고 player 데이터에는 영향 없다.
  for sf in "${scripts[@]}"; do
    nn="${sf%%-*}"
    python3 "$SKILL_DIR/scripts/prepare_narration.py" "$sf" "$tmp/preflight/$nn"
  done
  # 문서 집필 중에는 기존 읽기용 player를 빠르게 다시 색인한다. 이미 완성된
  # 음성이 있다면 player 데이터에만 재사용하되, 공개 audio 폴더는 건드리지 않는다.
  if [ -d "$FOLDER/audio" ]; then
    cp -R "$FOLDER/audio/." "$stage/audio/"
  fi
  echo "음성 합성 없이 현재 챕터 메뉴가 든 읽기용 player를 만듭니다." >&2
elif [ "$REUSE_AUDIO" = 1 ]; then
  for sf in "${scripts[@]}"; do
    nn="${sf%%-*}"
    [ -f "$FOLDER/audio/$nn.mp3" ] || { echo "재사용할 음성이 없습니다: audio/$nn.mp3" >&2; exit 1; }
    [ -f "$FOLDER/audio/$nn.cues.json" ] || { echo "재사용할 큐가 없습니다: audio/$nn.cues.json" >&2; exit 1; }
    cp "$FOLDER/audio/$nn.mp3" "$FOLDER/audio/$nn.cues.json" "$stage/audio/"
  done
  [ ! -f "$FOLDER/audio/render-warnings.json" ] || cp "$FOLDER/audio/render-warnings.json" "$stage/audio/"
  echo "기존 음성과 큐를 재사용하고 player만 다시 만듭니다." >&2
else
  # 먼저 모든 섹션을 문단과 TTS 세그먼트로 분할한다. @fig 문단의
  # [[stage:stage-id]] 마커는 발음하지 않고 세그먼트 경계로 보존한다. 그래야
  # qwen이 폴더 전체를 한 배치 큐로 렌더하면서도 실제 장면 시작 시각을 남긴다.
  for sf in "${scripts[@]}"; do
    nn="${sf%%-*}"
    cdir="$tmp/$nn"; mkdir -p "$cdir"
    python3 "$SKILL_DIR/scripts/prepare_narration.py" "$sf" "$cdir"
  done

# 폴더 전체 TTS 세그먼트를 내부 분할하고 길이별 x-vector 텐서 배치로 사전 렌더한다.
# qwen_batch.py는 각 *.tts.txt를 sibling *.tts.wav로 다시 합친다.
  if [ "$ENGINE" = qwen ]; then
    "$QWEN_PY" "$SKILL_DIR/scripts/qwen_batch.py" "$tmp" "$QWEN_REF_AUDIO" "$QWEN_REF_TEXT_FILE" "$QWEN_MODEL" \
      || { echo "qwen 사전 렌더 실패 — 기존 산출물은 유지합니다." >&2; exit 1; }
    if [ -f "$tmp/qwen-partial-failures.json" ]; then
      cp "$tmp/qwen-partial-failures.json" "$stage/audio/render-warnings.json"
      echo "일부 Qwen 조각을 격리했습니다. audio/render-warnings.json에서 누락 문장을 확인하세요." >&2
    fi
  fi

  for sf in "${scripts[@]}"; do
  nn="${sf%%-*}"
  cdir="$tmp/$nn"

  # 세그먼트별 렌더 → 문단 WAV 결합 → 큐(start·duration·type·stages) 누적
  : > "$cdir/list.txt"
  cues="["; first=1; acc="0"; k=0
  for pdir in "$cdir"/paragraphs/p[0-9][0-9][0-9]; do
    k=$((k+1))
    cwav="$cdir/c$(printf '%03d' "$k").wav"
    para_list="$pdir/list.txt"; : > "$para_list"
    para_acc="0"; stage_items=""; stage_first=1
    while IFS=$'\t' read -r stage_id segment_file; do
      [ -z "$segment_file" ] && continue
      infile="$pdir/$segment_file"
      swav="$pdir/${segment_file%.txt}.render.wav"
      if [ "$stage_id" != "-" ]; then
        offset="$(awk -v a="$para_acc" 'BEGIN{printf "%.3f", a+0}')"
        [ $stage_first -eq 1 ] && stage_first=0 || stage_items="$stage_items,"
        stage_items="$stage_items{\"id\":\"$stage_id\",\"offset\":$offset}"
      fi
      render_chunk "$infile" "$swav"
      seg_dur="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$swav")"
      para_acc="$(awk -v a="$para_acc" -v dd="$seg_dur" 'BEGIN{printf "%.6f", a+dd}')"
      echo "file '$swav'" >> "$para_list"
    done < "$pdir/segments.tsv"
    ffmpeg -y -loglevel error -f concat -safe 0 -i "$para_list" -ar 24000 -ac 1 -c:a pcm_f32le "$cwav"
    dur="$(awk -v a="$para_acc" 'BEGIN{printf "%.3f", a+0}')"
    tag="$(sed -n '1p' "$pdir/tag.txt")"; [ -z "$tag" ] && tag="p"
    start="$(awk -v a="$acc" 'BEGIN{printf "%.3f", a+0}')"
    [ $first -eq 1 ] && first=0 || cues="$cues,"
    cue="{\"start\":$start,\"duration\":$dur,\"type\":\"$tag\""
    [ -z "$stage_items" ] || cue="$cue,\"stages\":[$stage_items]"
    cues="$cues$cue}"
    acc="$(awk -v a="$acc" -v dd="$dur" 'BEGIN{printf "%.6f", a+dd}')"
    echo "file '$cwav'" >> "$cdir/list.txt"
  done
  cues="$cues]"

  if [ "$k" -eq 0 ]; then
    echo "건너뜀(문단 없음): $sf" >&2
    continue
  fi

  ffmpeg -y -loglevel error -f concat -safe 0 -i "$cdir/list.txt" -codec:a libmp3lame -qscale:a 4 "$stage/audio/$nn.mp3"
  printf '%s' "$cues" > "$stage/audio/$nn.cues.json"
    echo "렌더: $sf → audio/$nn.mp3  (문단 ${k}개, 엔진 ${ENGINE}/${VOICE})"
  done
fi

# --- player.html 생성(완료 전에는 원래 폴더를 건드리지 않는다) ---
python3 - "$FOLDER" "$MARKED" "$stage" <<'PY'
import sys, os, glob, json, re, html

folder, marked_path, artifact_root = sys.argv[1], sys.argv[2], sys.argv[3]
os.chdir(folder)

def read(p):
    with open(p, encoding="utf-8") as f:
        return f.read()

def split_front_matter(text):
    m = re.match(r'^---[ \t]*\n(.*?)\n---[ \t]*\n?(.*)$', text, re.DOTALL)
    if not m:
        return {}, text
    meta = {}
    for line in m.group(1).splitlines():
        if ':' in line:
            k, v = line.split(':', 1)
            meta[k.strip()] = v.strip()
    return meta, m.group(2)

def doc_h1_title(md):
    for line in md.splitlines():
        s = line.strip()
        if s.startswith('# '):
            return s[2:].strip()
    return None

def strip_tags_for_display(body):
    out = []
    for para in re.split(r'\n\s*\n', body.strip()):
        text = re.sub(r'^@(p|fig|code|table|note|gate)[ \t]+', '', para.strip())
        text = re.sub(r'\[\[(?:stage|anim):[A-Za-z][A-Za-z0-9_-]*\]\][ \t]*', '', text)
        out.append(text)
    return "\n\n".join(out)

render_warnings = []
warning_path = os.path.join(artifact_root, 'audio', 'render-warnings.json')
if os.path.exists(warning_path):
    try:
        payload = json.loads(read(warning_path))
        if isinstance(payload, dict) and isinstance(payload.get('failures'), list):
            render_warnings = payload['failures']
    except Exception:
        render_warnings = []

sections = []
for sf in sorted(glob.glob('*.script.md')):
    nn = sf.split('-', 1)[0]
    meta, script_body = split_front_matter(read(sf))
    doc_md, doc_name = "", None
    for cand in sorted(glob.glob(nn + '-*.md')):
        if cand.endswith('.script.md'):
            continue
        doc_name = cand; doc_md = read(cand); break
    title = meta.get('title') or (doc_h1_title(doc_md) if doc_md else None) or os.path.splitext(sf)[0]
    cues = []
    cpath = os.path.join(artifact_root, 'audio', '%s.cues.json' % nn)
    if os.path.exists(cpath):
        try: cues = json.loads(read(cpath))
        except Exception: cues = []
    staged_audio = os.path.join(artifact_root, 'audio', '%s.mp3' % nn)
    apath = 'audio/%s.mp3' % nn
    section_warnings = [
        row for row in render_warnings
        if isinstance(row, dict) and str(row.get('part', '')).startswith(nn + '/')
    ]
    sections.append({
        'nn': nn, 'title': title,
        'stem': (os.path.splitext(doc_name)[0] if doc_name else nn),
        'doc': doc_md if doc_md else '_(학습 문서 %s-*.md 를 찾지 못했습니다.)_' % nn,
        'script': strip_tags_for_display(script_body),
        'audio': apath if os.path.exists(staged_audio) else '',
        'cues': cues,
        'warnings': section_warnings,
    })

if not sections:
    sys.exit('섹션을 구성하지 못했습니다.')

point_name = os.path.basename(folder.rstrip('/'))
marked_js = read(marked_path)

TEMPLATE = r'''<!doctype html>
<html lang="ko">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>__TITLE__ · 낭독 학습</title>
<link rel="stylesheet" href="https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@11.9.0/build/styles/github.min.css">
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.18.4/dist/katex.min.css">
<style>
@import url('https://cdn.jsdelivr.net/gh/orioncactus/pretendard@v1.3.9/dist/web/static/pretendard.min.css');
:root{
  --paper:#fffdf9; --bg:#ece5d9; --ink:#221f1a; --soft:#544c40; --faint:#8b8173; --line:#e8dfcd;
  --accent:#b3541b; --accent-soft:#f3e7d6; --ring:rgba(179,84,27,.55);
  --info:#2b6cb0; --info-bg:#eef5fb; --warn:#b5560e; --warn-bg:#fdf1e3;
  --gate:#6b4fb0; --gate-bg:#f3effb; --note-bg:#f7f2e9; --bar:#2b2721;
}
*{box-sizing:border-box} html{scroll-behavior:smooth} html,body{margin:0}
body{font-family:'Pretendard',-apple-system,"Apple SD Gothic Neo",Segoe UI,Roboto,sans-serif;
  background:var(--bg); color:var(--ink); line-height:1.9; letter-spacing:-.003em; padding-bottom:84px}
#progress{position:fixed; top:0; left:0; height:3px; background:var(--accent); width:0; z-index:80; transition:width .1s}
#wrap{display:flex; min-height:100vh}
#side{width:264px; flex:0 0 264px; position:sticky; top:0; align-self:flex-start; height:100vh;
  overflow-y:auto; padding:26px 14px 100px; border-right:1px solid var(--line)}
#side h1{font-size:11px; letter-spacing:.12em; color:var(--faint); font-weight:700; margin:6px 10px 16px; text-transform:uppercase}
.navrow{display:flex; gap:9px; align-items:flex-start; width:100%; text-align:left; background:none; border:0;
  border-radius:9px; padding:9px 10px; cursor:pointer; color:var(--soft); font:inherit; line-height:1.4}
.navrow:hover{background:var(--accent-soft)}
.navrow.active{background:var(--accent-soft)}
.navrow.active .nt{color:var(--accent); font-weight:700}
.navrow .nn{color:var(--faint); font-variant-numeric:tabular-nums; font-weight:700; font-size:12px; padding-top:2px}
.navrow .nt{font-size:13.5px}
.subtoc{margin:2px 0 8px 30px; display:flex; flex-direction:column; border-left:1px solid var(--line)}
.sublink{display:block; color:var(--faint); text-decoration:none; font-size:12px; line-height:1.4; padding:5px 10px; border-left:2px solid transparent; margin-left:-1px}
.sublink:hover{color:var(--soft)}
.sublink.on{color:var(--accent); border-left-color:var(--accent); font-weight:600}
#content{flex:1 1 auto; min-width:0; display:flex; justify-content:center; padding:0 24px}
.col{width:100%; max-width:var(--colw,720px)}
.sheet{width:100%; margin:34px 0 18px; background:var(--paper); border:1px solid var(--line);
  border-radius:16px; box-shadow:0 12px 44px rgba(60,40,20,.09); padding:50px 56px}
#doc{font-size:17px; overflow-wrap:break-word}
#doc>*{scroll-margin-top:20px; transition:opacity .35s ease}
#doc .audio-warning{margin:0 0 1.5em; padding:13px 16px; border:1px solid #ecd3b4; border-left:4px solid var(--warn); border-radius:10px; background:var(--warn-bg); color:#77400f; font-size:.88em; line-height:1.65}
#doc>h1:first-child{font-size:1.95em; line-height:1.28; font-weight:800; letter-spacing:-.02em; margin:.1em 0 1em; padding-bottom:.65em; border-bottom:2px solid var(--ink)}
#doc>h1:first-child::before{content:'학습 문서 · 튜터식 심층'; display:block; font-size:.38em; font-weight:700; letter-spacing:.14em; color:var(--accent); margin-bottom:1.1em}
#doc h2{font-size:1.38em; font-weight:800; letter-spacing:-.02em; margin:2.2em 0 .7em; line-height:1.35}
#doc h2::before{content:''; display:block; width:32px; height:3px; background:var(--accent); border-radius:2px; margin-bottom:.5em}
#doc h3{font-size:1.1em; font-weight:700; margin:1.5em 0 .5em}
#doc p,#doc li{font-size:1rem}
#doc p{margin:1.05em 0; text-wrap:pretty}
#doc strong{font-weight:700; color:#000}
#doc a{color:var(--accent)}
#doc em{font-style:normal; background:linear-gradient(transparent 60%,#f6dcbb 60%); padding:0 .04em}
#doc hr{border:0; border-top:1px solid var(--line); margin:2em 0}
#doc :not(pre)>code{background:#f1ece1; color:#7a3d12; padding:.1em .42em; border-radius:6px; font-size:.9em; font-family:'SF Mono',ui-monospace,Menlo,monospace}
#doc pre{background:#faf6ee; border:1px solid var(--line); border-radius:12px; padding:16px 18px; overflow-x:auto; line-height:1.62; font-size:13.5px; position:relative}
#doc pre code{font-family:'SF Mono',ui-monospace,Menlo,monospace}
#doc pre.code{padding-top:36px}
#doc pre.code::before{content:''; position:absolute; top:14px; left:18px; width:9px; height:9px; border-radius:50%; background:#e0a99a; box-shadow:15px 0 #e6cf9a,30px 0 #a6c9a0}
#doc pre.code::after{content:attr(data-badge); position:absolute; top:11px; right:16px; font-size:11px; color:var(--faint); letter-spacing:.08em; max-width:60%; overflow:hidden; text-overflow:ellipsis; white-space:nowrap}
#doc pre.code:not([data-badge])::after{content:'code'}
#doc pre.code[data-badge]::after{letter-spacing:.01em; max-width:72%}
#doc pre.code[data-src="file"]::after, #doc pre.code[data-src="ref"]::after{font-family:'SF Mono',ui-monospace,Menlo,monospace}
#doc pre.diagram{background:#fcf9f3; border-style:dashed; padding-top:34px}
#doc pre.diagram::after{content:'그림'; position:absolute; top:11px; right:16px; font-size:11px; color:var(--faint); letter-spacing:.08em}
#doc pre.mermaid-card{background:var(--paper); border:1px solid var(--line); border-style:solid; padding:20px; text-align:center; white-space:normal; line-height:normal; position:relative}
#doc pre.mermaid-card::before, #doc pre.mermaid-card::after{content:none}
#doc pre.mermaid-card svg{max-width:100%; height:auto}
/* Mermaid 문법 오류 카드 — 조용히 삼키지 않고 경고 + 원본 코드로 보여 준다 */
#doc pre.mermaid-error{background:var(--warn-bg); border-color:#ecd3b4}
#doc pre.mermaid-error::before, #doc pre.mermaid-error::after{content:none}
.mm-errmsg{white-space:normal; font-family:'Pretendard',sans-serif; font-size:13.5px; line-height:1.6; color:var(--warn); font-weight:600; border-bottom:1px dashed #ecd3b4; padding-bottom:10px; margin-bottom:12px}
/* 다이어그램 확대·이동 컨트롤 */
.mm-controls{position:absolute; top:8px; right:8px; display:flex; gap:2px; z-index:5; background:var(--paper); border:1px solid var(--line); border-radius:8px; padding:2px; opacity:.45; transition:opacity .15s}
#doc pre.mermaid-card:hover .mm-controls, .mm-controls:focus-within{opacity:1}
.mm-controls button{width:26px; height:26px; border:0; background:none; color:var(--soft); cursor:pointer; border-radius:6px; font-size:13px; line-height:1; display:flex; align-items:center; justify-content:center; font-family:inherit}
.mm-controls button:hover{background:var(--accent-soft); color:var(--accent)}
.mm-viewport{overflow:auto}
.mm-canvas{display:block}
#doc pre.mermaid-card.mm-zoomed .mm-viewport{max-height:75vh; cursor:grab}
.vega-card{background:var(--paper)!important; border:1px solid var(--line)!important; border-style:solid!important; padding:18px!important; white-space:normal!important; overflow:visible!important}
.vega-card::before,.vega-card::after{content:none!important}
.vega-host{width:100%; min-height:220px; display:flex; justify-content:center; align-items:center}
.vega-host>div,.vega-host canvas,.vega-host svg{max-width:100%}
.vega-error{background:var(--warn-bg)!important; border-color:#ecd3b4!important}
.vega-errmsg{white-space:normal; font-family:'Pretendard',sans-serif; font-size:13.5px; line-height:1.6; color:var(--warn); font-weight:600; border-bottom:1px dashed #ecd3b4; padding-bottom:10px; margin-bottom:12px}
.mm-viewport.dragging, .mm-ov-viewport.dragging{cursor:grabbing!important; user-select:none}
/* '크게 보기' 전체 화면 오버레이 */
.mm-overlay{position:fixed; inset:0; z-index:95; background:var(--paper); display:flex; flex-direction:column}
.mm-ov-bar{display:flex; justify-content:space-between; align-items:center; gap:12px; padding:10px 18px; border-bottom:1px solid var(--line); background:var(--bg); font-size:12.5px; color:var(--faint); flex:0 0 auto}
.mm-ov-acts{display:flex; gap:6px}
.mm-ov-bar button{border:1px solid var(--line); background:var(--paper); border-radius:8px; min-width:32px; height:30px; padding:0 10px; cursor:pointer; font:inherit; font-size:13px; color:var(--soft)}
.mm-ov-bar button:hover{background:var(--accent-soft); color:var(--accent)}
.mm-ov-viewport{flex:1 1 auto; overflow:auto; padding:34px; text-align:center; cursor:grab}
#doc .hljs{background:transparent; padding:0}
#doc img{display:block; max-width:100%; height:auto; margin:1.6em auto; border:1px solid var(--line); border-radius:12px; background:#fff; padding:12px}
#doc blockquote{--cq:var(--accent); margin:1.6em 0; padding:16px 22px; border-radius:10px; border:1px solid var(--line); border-left:4px solid var(--cq); background:var(--note-bg); color:#453e32; line-height:1.85}
#doc blockquote p{margin:.55em 0} #doc blockquote p:first-child{margin-top:0} #doc blockquote p:last-child{margin-bottom:0}
#doc blockquote p:first-child>strong:first-child{color:var(--cq)}
#doc blockquote.info{--cq:var(--info); background:var(--info-bg)}
#doc blockquote.warn{--cq:var(--warn); background:var(--warn-bg)}
#doc blockquote.gate{--cq:var(--gate); background:var(--gate-bg)}
#doc table{border-collapse:collapse; width:100%; margin:1.4em 0; font-size:.92em}
#doc th,#doc td{padding:9px 12px; text-align:left; border-bottom:1px solid var(--line)}
#doc th{background:#f2ebdf; font-weight:700} #doc tbody tr:nth-child(even){background:#fbf7ef}
#doc ol{padding-left:0; counter-reset:step; list-style:none}
#doc ol>li{position:relative; padding-left:2.3em; margin:.7em 0}
#doc ol>li::before{counter-increment:step; content:counter(step); position:absolute; left:0; top:.02em; width:1.55em; height:1.55em; background:var(--accent); color:#fff; border-radius:50%; font-size:.78em; font-weight:700; display:flex; align-items:center; justify-content:center}
#doc ul{padding-left:1.2em} #doc ul li{margin:.5em 0}
#doc .anc{display:inline-flex; align-items:center; justify-content:center; min-width:1.35em; height:1.35em; background:var(--accent); color:#fff; border-radius:50%; font-size:.76em; font-weight:700; padding:0 .18em; vertical-align:.06em}
#doc details{margin:1em 0 .3em; border:1px solid var(--line); border-radius:10px; background:var(--paper); padding:0 18px}
#doc summary{cursor:pointer; padding:12px 0; color:var(--cq,var(--gate)); font-weight:600; list-style:none; display:flex; align-items:center; gap:8px}
#doc summary::-webkit-details-marker{display:none}
#doc summary::before{content:'▸'; color:var(--cq,var(--gate)); font-size:.9em; transition:transform .18s ease}
#doc details[open] summary{border-bottom:1px solid var(--line)}
#doc details[open] summary::before{transform:rotate(90deg)}
#doc details>*:not(summary){padding-bottom:14px} #doc details[open] summary{margin-bottom:2px}
/* 낭독 하이라이트: 재생 중에만 '지금 문단'만 또렷하고 나머지는 물러난다(포커스+거터). 멈추면 전부 정상. */
/* 주변 흐림은 옵션(#dimtoggle) — .dimoff면 흐림만 끄고, 활성 문단 레일은 유지 */
#doc.playing:not(.dimoff)>*{opacity:.32}
#doc.playing:not(.dimoff)>.hl{opacity:1}
#doc.playing>.hl{position:relative}
#doc.playing>.hl::before{content:''; position:absolute; left:-18px; top:.2em; bottom:.2em; width:3px; border-radius:2px; background:var(--accent)}
#doc.playing>blockquote.hl::before{display:none}   /* 콜아웃은 이미 좌측 컬러 바가 있어 레일 생략 */
#scriptbox{width:100%; margin:0 0 30px}
#scriptbox details{border:1px dashed var(--line); border-radius:12px; background:var(--paper)}
#scriptbox summary{cursor:pointer; padding:12px 18px; color:var(--faint); font-size:13.5px}
#scripttext{padding:4px 22px 20px; white-space:pre-wrap; color:#5c564c; font-size:14.5px; line-height:1.85}
#bar{position:fixed; left:0; right:0; bottom:0; height:66px; background:var(--bar); color:#f3efe8; display:flex; align-items:center; gap:14px; padding:0 18px; z-index:70; box-shadow:0 -6px 20px rgba(0,0,0,.14)}
#bar button{background:none; border:0; color:#f3efe8; cursor:pointer; line-height:1}
#bar button:disabled,#bar select:disabled,#bar input:disabled{cursor:not-allowed; opacity:.38}
#bar.audio-pending #time{min-width:220px; color:#e6c9a8}
#bar .icon{font-size:20px; width:34px; height:34px; border-radius:50%; display:inline-flex; align-items:center; justify-content:center}
#bar .icon:hover{background:rgba(255,255,255,.12)}
#playpause{font-size:24px; background:var(--accent); width:42px; height:42px}
#curlabel{font-size:13px; color:#cfc7ba; min-width:150px; max-width:230px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap}
#seekwrap{flex:1 1 auto; display:flex; align-items:center; gap:10px; min-width:120px}
#seek{flex:1 1 auto; accent-color:var(--accent); cursor:pointer}
#time{font-size:12px; color:#cfc7ba; font-variant-numeric:tabular-nums; min-width:86px; text-align:right}
#speed{background:#3a352e; color:#f3efe8; border:1px solid #55504785; border-radius:7px; padding:5px 7px; font:inherit; font-size:13px; cursor:pointer}
#dimtoggle{margin-left:2px; font-size:12px; padding:5px 10px; border:1px solid #55504785; border-radius:7px; background:#3a352e; color:#cfc7ba; cursor:pointer; white-space:nowrap}
#dimtoggle.on{background:var(--accent); color:#fff; border-color:transparent}
.hint{color:#a49c8f; font-size:11px}
#navtoggle{display:none; position:fixed; top:10px; left:12px; z-index:78; background:var(--paper); color:var(--ink); border:1px solid var(--line); border-radius:9px; width:38px; height:38px; font-size:18px; cursor:pointer; box-shadow:0 2px 8px rgba(0,0,0,.12)}
#ffind{position:fixed; top:22px; left:50%; z-index:90; pointer-events:none; background:rgba(20,18,15,.82); color:#fff; font-size:13px; font-weight:600; letter-spacing:.02em; padding:7px 14px; border-radius:20px; opacity:0; transform:translateX(-50%) translateY(-6px); transition:opacity .14s, transform .14s}
#ffind.show{opacity:1; transform:translateX(-50%) translateY(0)}
#gatehint{position:fixed; left:50%; bottom:82px; z-index:90; pointer-events:none; background:var(--gate); color:#fff; font-size:14px; font-weight:600; padding:9px 16px; border-radius:12px; box-shadow:0 4px 16px rgba(0,0,0,.22); opacity:0; transform:translateX(-50%) translateY(6px); transition:opacity .16s, transform .16s}
#gatehint.show{opacity:1; transform:translateX(-50%) translateY(0)}
@media (max-width:900px){
  #side{position:fixed; z-index:75; transform:translateX(-100%); transition:transform .2s; background:var(--paper); box-shadow:2px 0 16px rgba(0,0,0,.15)}
  #side.open{transform:none}
  #navtoggle{display:block}
  #content{padding:0 12px} .sheet{padding:32px 22px 40px}
  #curlabel,.hint{display:none}
}
@media (prefers-reduced-motion: reduce){ *,*::before,*::after{animation-duration:.01ms!important; transition-duration:.01ms!important} html{scroll-behavior:auto} }
</style>
</head>
<body>
<div id="progress"></div>
<button id="navtoggle" aria-label="목차 열기">☰</button>
<div id="wrap">
  <aside id="side"><h1>__POINT__</h1><div id="sections"></div></aside>
  <div id="content"><div class="col">
    <div class="sheet"><article id="doc"></article></div>
    <div id="scriptbox"><details>
      <summary>▸ 낭독 스크립트 보기 (귀로 듣는 내용)</summary>
      <div id="scripttext"></div>
    </details></div>
  </div></div>
</div>
<div id="bar">
  <button id="prev" class="icon" title="이전 섹션 (p)">⏮</button>
  <button id="playpause" class="icon" title="재생/일시정지 (space)">▶︎</button>
  <button id="next" class="icon" title="다음 섹션 (n)">⏭</button>
  <span id="curlabel"></span>
  <div id="seekwrap"><input id="seek" type="range" min="0" max="1000" value="0" step="1"><span id="time">0:00 / 0:00</span></div>
  <label style="font-size:12px;color:#cfc7ba">배속
    <select id="speed"><option>0.75</option><option selected>1</option><option>1.25</option><option>1.5</option><option>1.75</option><option>2</option></select>
  </label>
  <label style="font-size:12px;color:#cfc7ba">폭
    <button id="wnarrow" title="본문 좁게">−</button><span id="wval" style="font-size:12px;color:#cfc7ba;min-width:34px;display:inline-block;text-align:center">기본</span><button id="wwide" title="본문 넓게">+</button>
  </label>
  <button id="dimtoggle" title="재생 중 주변 흐림 켜기/끄기">흐림 켬</button>
  <span class="hint">space 탭=재생/정지 · 길게=2배속 · ←/→ 5초 · ↑/↓ 배속 · n/p 섹션</span>
</div>
<div id="ffind">2배속</div>
<div id="gatehint">먼저 떠올려 보세요 · 스페이스로 계속</div>
<audio id="audio" preload="metadata"></audio>

<script>/*__MARKED__*/</script>
<script src="https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@11.9.0/build/highlight.min.js"></script>
<script src="https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@11.9.0/build/languages/groovy.min.js"></script>
<script src="https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js"></script>
<script src="https://cdn.jsdelivr.net/npm/katex@0.18.4/dist/katex.min.js"></script>
<script src="https://cdn.jsdelivr.net/npm/katex@0.18.4/dist/contrib/auto-render.min.js"></script>
<script src="https://cdn.jsdelivr.net/npm/vega@5"></script>
<script src="https://cdn.jsdelivr.net/npm/vega-lite@5"></script>
<script src="https://cdn.jsdelivr.net/npm/vega-embed@6"></script>
<script>
const S = /*__DATA__*/;
const INITIAL = __INITIAL__;
const SPEEDS=[0.75,1,1.25,1.5,1.75,2];
const docEl=document.getElementById('doc'), scriptEl=document.getElementById('scripttext');
const navEl=document.getElementById('sections'), audio=document.getElementById('audio');
const curLabel=document.getElementById('curlabel'), seek=document.getElementById('seek');
const timeEl=document.getElementById('time'), speedSel=document.getElementById('speed'), ppBtn=document.getElementById('playpause');
const ffind=document.getElementById('ffind'), gatehint=document.getElementById('gatehint'), progEl=document.getElementById('progress');
const barEl=document.getElementById('bar');
let cur=-1, curCues=[], curMap=[], curHl=-1, pausedGates=new Set(), audioReady=false;
let rows=[], subLinks=[], subHeads=[];

if(window.marked&&marked.setOptions) marked.setOptions({gfm:true, breaks:false});
// 코드 펜스 정보 문자열(```lang file=경로:줄 | example | pseudo | ref=경로 | adapted=경로 | cmd)을 보존한다.
// marked는 첫 단어(언어)만 class로 남기므로, 출처 키워드를 data-* 속성으로 옮겨 코드 카드 배지가 읽게 한다(notation.md).
if(window.marked&&marked.use){ try{ marked.use({renderer:{code:function(code, info, escaped){
  var toks=String(info||'').trim().split(/\s+/).filter(Boolean), lang=toks[0]||'', src='', path='';
  if(lang==='pseudo') src='pseudo';
  toks.slice(1).forEach(function(t){ var m=t.match(/^(file|ref|adapted)=(.+)$/); if(m){ src=m[1]; path=m[2]; } else if(/^(example|pseudo|cmd)$/.test(t)) src=t; });
  var attrs=(src?' data-src="'+src+'"':'')+(path?' data-path="'+esc(path)+'"':'');
  var body=escaped?code:esc(code);
  return '<pre'+attrs+'><code'+(lang?' class="language-'+esc(lang)+'"':'')+'>'+body+'</code>\n</pre>\n';
}}}); }catch(e){} }
if(window.mermaid) try{ mermaid.initialize({startOnLoad:false, theme:'base', htmlLabels:false, flowchart:{htmlLabels:false}, themeVariables:{fontFamily:"'Pretendard',sans-serif", fontSize:'14px', primaryColor:'#fff8f0', primaryBorderColor:'#b3541b', primaryTextColor:'#221f1a', lineColor:'#8a8377', secondaryColor:'#eef7ee', tertiaryColor:'#fdf3f0', background:'#fffdf9'}}); }catch(e){}
function md(t){
  try{
    // marked는 \( \) \[ \]를 Markdown 이스케이프로 소비한다. 구분자만
    // 한 겹 더 보호해 HTML에도 백슬래시가 남게 한 뒤 KaTeX가 읽게 한다.
    // 코드 펜스와 인라인 코드는 원문을 보존한다.
    var chunks=String(t).split(/(```[\s\S]*?```|~~~[\s\S]*?~~~|`[^`\n]*`)/g);
    var protectedMath=chunks.map(function(chunk,index){
      return index%2?chunk:chunk.replace(/\\([()[\]])/g,'\\\\$1');
    }).join('');
    return window.marked?marked.parse(protectedMath):protectedMath;
  }catch(e){ return '<pre>'+esc(t)+'</pre>'; }
}
function esc(x){return x.replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));}
function fmt(t){t=Math.floor(t||0);return Math.floor(t/60)+':'+String(t%60).padStart(2,'0');}

// --- Mermaid 다이어그램: 오류 카드 · 확대/이동 · 크게 보기 ---
var mmDrag=null;   // 카드/오버레이 공용 드래그-스크롤 상태
window.addEventListener('mousemove', function(e){ if(!mmDrag) return; mmDrag.vw.scrollLeft=mmDrag.l-(e.clientX-mmDrag.x); mmDrag.vw.scrollTop=mmDrag.t-(e.clientY-mmDrag.y); });
window.addEventListener('mouseup', function(){ if(mmDrag){ mmDrag.vw.classList.remove('dragging'); mmDrag=null; } });

// 렌더 실패를 조용히 삼키지 않는다 — 경고 + 원본 코드를 그대로 보여 줘 작성자가 바로 알아채게 한다.
function mmError(pre, err){
  if(pre.classList.contains('mermaid-error')) return;
  pre.classList.add('mermaid-error');
  var d=document.createElement('div'); d.className='mm-errmsg';
  var m=(err&&err.message)?String(err.message).split('\n')[0].slice(0,160):'';
  d.textContent='⚠ 다이어그램 렌더 실패 — Mermaid 문법 오류입니다. 아래는 원본 코드입니다.'+(m?' · '+m:'');
  pre.insertBefore(d, pre.firstChild);
}
// 렌더 성공: 카드에 뷰포트·캔버스를 짓고 확대(＋/−/↺)·크게 보기(⤢)·Ctrl/⌘+휠 줌·드래그 이동을 단다.
function mmCard(pre, svgText){
  var cv=document.createElement('div'); cv.className='mm-canvas'; cv.innerHTML=svgText;
  var svg=cv.querySelector('svg');
  if(!svg){ mmError(pre, {message:'SVG가 생성되지 않았습니다'}); return; }
  var vw=document.createElement('div'); vw.className='mm-viewport'; vw.appendChild(cv);
  var ctr=document.createElement('div'); ctr.className='mm-controls';
  ctr.innerHTML='<button data-a="out" title="축소">−</button><button data-a="in" title="확대">＋</button><button data-a="fit" title="원래 크기">↺</button><button data-a="max" title="크게 보기 (전체 화면)">⤢</button>';
  pre.textContent=''; pre.appendChild(ctr); pre.appendChild(vw); pre.classList.add('mermaid-card');
  var zoom=1, base=0;
  function apply(){
    if(zoom===1){ svg.style.maxWidth='100%'; svg.style.width=''; }
    else{ if(!base) base=svg.getBoundingClientRect().width||600; svg.style.maxWidth='none'; svg.style.width=Math.round(base*zoom)+'px'; }
    pre.classList.toggle('mm-zoomed', zoom>1);
  }
  function step(d){ zoom=Math.max(1, Math.min(6, zoom*(d>0?1.25:0.8))); if(Math.abs(zoom-1)<0.08) zoom=1; apply(); }
  ctr.onclick=function(e){ var b=e.target.closest('button'); if(!b) return; b.blur(); var a=b.getAttribute('data-a');
    if(a==='in') step(1); else if(a==='out') step(-1); else if(a==='fit'){ zoom=1; apply(); } else if(a==='max') mmExpand(svg); };
  vw.addEventListener('wheel', function(e){ if(!(e.ctrlKey||e.metaKey)) return; e.preventDefault(); step(e.deltaY<0?1:-1); }, {passive:false});
  vw.addEventListener('mousedown', function(e){ if(zoom===1) return; mmDrag={vw:vw,x:e.clientX,y:e.clientY,l:vw.scrollLeft,t:vw.scrollTop}; vw.classList.add('dragging'); e.preventDefault(); });
  svg.addEventListener('dblclick', function(){ mmExpand(svg); });
}
// '크게 보기' — 화면 전체 오버레이에 복제해 띄운다. 휠/버튼 줌, 드래그 이동, Esc/닫기.
function mmExpand(svg){
  var ov=document.createElement('div'); ov.className='mm-overlay';
  ov.innerHTML='<div class="mm-ov-bar"><span>드래그·스크롤 이동 · Ctrl/⌘+휠 또는 ＋/− 확대 · Esc 닫기</span><span class="mm-ov-acts"><button data-a="out" title="축소">−</button><button data-a="in" title="확대">＋</button><button data-a="close">✕ 닫기</button></span></div><div class="mm-ov-viewport"></div>';
  var vw=ov.querySelector('.mm-ov-viewport');
  var clone=svg.cloneNode(true);
  clone.style.maxWidth='none'; clone.style.height='auto'; clone.removeAttribute('height');
  vw.appendChild(clone);
  document.body.appendChild(ov); document.body.style.overflow='hidden';
  var vb=svg.viewBox&&svg.viewBox.baseVal, nat=(vb&&vb.width)||svg.getBoundingClientRect().width||800;
  var z=Math.max(1, Math.min(3, (vw.clientWidth-100)/nat));   // 처음엔 화면 폭에 맞춰 크게(원본보다 작게는 안 함)
  function apply(){ clone.style.width=Math.round(nat*z)+'px'; }
  function close(){ document.removeEventListener('keydown', onKey, true); document.body.style.overflow=''; ov.remove(); }
  function onKey(e){ if(e.key==='Escape'){ e.preventDefault(); e.stopPropagation(); close(); } }
  apply();
  document.addEventListener('keydown', onKey, true);
  ov.querySelector('.mm-ov-bar').onclick=function(e){ var b=e.target.closest('button'); if(!b) return; var a=b.getAttribute('data-a');
    if(a==='close') close(); else if(a){ z=Math.max(0.4, Math.min(8, z*(a==='in'?1.25:0.8))); apply(); } };
  vw.addEventListener('wheel', function(e){ if(!(e.ctrlKey||e.metaKey)) return; e.preventDefault(); z=Math.max(0.4, Math.min(8, z*(e.deltaY<0?1.25:0.8))); apply(); }, {passive:false});
  vw.addEventListener('mousedown', function(e){ mmDrag={vw:vw,x:e.clientX,y:e.clientY,l:vw.scrollLeft,t:vw.scrollTop}; vw.classList.add('dragging'); e.preventDefault(); });
}

// KaTeX — 통화 기호와 충돌하는 단일 $ 구분자는 쓰지 않는다.
function renderMath(){
  if(!window.renderMathInElement) return;
  try{ renderMathInElement(docEl,{delimiters:[
    {left:'$$',right:'$$',display:true},
    {left:'\\[',right:'\\]',display:true},
    {left:'\\(',right:'\\)',display:false}
  ],throwOnError:false,ignoredTags:['script','noscript','style','textarea','pre','code']}); }catch(e){}
}

// Vega-Lite — JSON 명세를 차트로 승격하되 실패하면 오류와 원본을 함께 남긴다.
function renderVegaLite(){
  var codes=docEl.querySelectorAll('pre>code.language-vega-lite');
  codes.forEach(function(code){
    var pre=code.parentElement;
    if(!pre||pre.dataset.vegaMounted) return;
    pre.dataset.vegaMounted='1'; pre.classList.add('vega-card');
    if(!window.vegaEmbed) return;  // CDN을 못 불러오면 원본 JSON이 자연 후퇴다.
    var source=code.textContent, spec;
    try{ spec=JSON.parse(source); }
    catch(err){
      pre.classList.add('vega-error');
      var msg=document.createElement('div'); msg.className='vega-errmsg';
      msg.textContent='차트 렌더 실패 — Vega-Lite JSON을 확인하세요. · '+String(err.message||err).slice(0,180);
      pre.insertBefore(msg,pre.firstChild); return;
    }
    var host=document.createElement('div'); host.className='vega-host';
    code.style.display='none'; pre.appendChild(host);
    vegaEmbed(host,spec,{mode:'vega-lite',renderer:'svg',actions:false,config:{
      background:null,font:'Pretendard',axis:{labelFont:'Pretendard',titleFont:'Pretendard'},
      legend:{labelFont:'Pretendard',titleFont:'Pretendard'},title:{font:'Pretendard'}
    }}).then(function(result){ pre._vegaFinalize=result.finalize; }).catch(function(err){
      host.remove(); code.style.display=''; pre.classList.add('vega-error');
      var msg=document.createElement('div'); msg.className='vega-errmsg';
      msg.textContent='차트 렌더 실패 — Vega-Lite 명세를 확인하세요. · '+String(err.message||err).split('\n')[0].slice(0,180);
      pre.insertBefore(msg,pre.firstChild);
    });
  });
}

// 렌더된 문서에 시각 강화: 신택스 하이라이트 · 콜아웃 카드 · 코드/그림 구분 · 앵커 배지
function enhanceDoc(){
  // Mermaid 다이어그램 렌더(있으면). <pre> 태그는 유지하고 안에 SVG만 그려 넣어 하이라이트 정렬을 깨지 않는다.
  // 반드시 웹폰트(Pretendard) 로드가 끝난 뒤에 그린다 — mermaid는 렌더 시점의 글꼴로 글자 폭을 재서
  // 상자 크기를 정하므로, 폰트 도착 전에 그리면 한글 라벨이 좁게 측정돼 잘려 보인다.
  if(window.mermaid){ var mmCodes=docEl.querySelectorAll('pre>code.language-mermaid');
    if(mmCodes.length){ var drawMM=function(){ mmCodes.forEach(function(code){
        var pre=code.parentElement, src=code.textContent;
        if(!pre||pre.classList.contains('mermaid-card')||pre.classList.contains('mermaid-error')) return;
        var id='mmd'+Math.random().toString(36).slice(2,9);
        var fail=function(err){ mmError(pre, err); ['','d'].forEach(function(p){ var g=document.getElementById(p+id); if(g&&!pre.contains(g)) g.remove(); }); };   // mermaid가 body에 남긴 임시 노드 청소
        try{ mermaid.render(id, src).then(function(r){ mmCard(pre, r.svg); }).catch(fail); }catch(e){ fail(e); }
      }); };
      var afterLoad=(document.readyState==='complete')?Promise.resolve():new Promise(function(res){ window.addEventListener('load',res,{once:true}); });
      afterLoad.then(function(){ if(document.fonts&&document.fonts.load){ return Promise.all([document.fonts.load("14px Pretendard"),document.fonts.load("bold 14px Pretendard")]).catch(function(){}).then(function(){ return document.fonts.ready; }); } }).then(drawMM,drawMM);
    } }
  renderMath();
  renderVegaLite();
  if(window.hljs){ docEl.querySelectorAll('pre code[class*="language-"]:not(.language-mermaid):not(.language-vega-lite):not(.language-pseudo)').forEach(function(el){ try{hljs.highlightElement(el);}catch(e){} }); }
  docEl.querySelectorAll('blockquote').forEach(function(bq){
    var t=(bq.textContent||'').slice(0,46), c='';
    if(bq.querySelector('details')) c='gate';                 // 게이트 = 답을 접은 인출 블록(이모지에 의존하지 않음)
    else if(/오해/.test(t)) c='warn';
    else if(/심화|읽어보기|참고|배경|잠깐/.test(t)) c='info';
    if(c) bq.classList.add(c);
    var lead=bq.querySelector('strong')||bq.querySelector('p');  // 라벨 선두의 이모지 제거(문서가 조잡해 보이지 않게)
    if(lead) lead.innerHTML=lead.innerHTML.replace(/^\s*(?:🧠|💡|👏|🎉|🔥|📌|🚀|💥|✨|⭐|⚠|ℹ|✅|❗|❓|➡|✔)️?\s*/,'');
  });
  docEl.querySelectorAll('pre').forEach(function(pre){
    var code=pre.querySelector('code');
    if(code && /language-(?:mermaid|vega-lite)/.test(code.className||'')) return;   // 시각 렌더러가 맡는다
    var lang=!!(code&&/language-/.test(code.className||''));
    var s=pre.textContent||'', diag=/[│├─└┌┐┘▼▶►◄╭╮╯╰↑↓→←↔⟶⟵]|──|[①②③④⑤⑥⑦⑧⑨⑩⑪⑫]/.test(s);
    pre.classList.add(lang?'code':(diag?'diagram':'code'));   // 언어 없는 펜스(도식·절차 목록)는 '그림' 카드로
    // 코드 출처 배지(notation.md): 펜스 정보 문자열의 키워드를 카드 우상단 작은 글씨로. 본문 문단으로 쓰지 않는다.
    var src=pre.getAttribute('data-src')||'', path=pre.getAttribute('data-path')||'';
    var badge={example:'예제 · 실제 파일 아님', pseudo:'의사코드 · 실행 코드 아님', cmd:'명령 예제 · 실제 스크립트 아님',
               file:path, ref:'참조 구현 · '+path, adapted:'축약 예제 · 원본 '+path+' 과 다름'}[src];
    if(badge){ pre.setAttribute('data-badge', badge); pre.title=badge; }
  });
  docEl.querySelectorAll('p,li').forEach(function(el){
    if(/[❶-❿]/.test(el.textContent)) el.innerHTML=el.innerHTML.replace(/([❶-❿])/g,'<span class="anc">$1</span>');
  });
  docEl.querySelectorAll('p,li,h1,h2,h3,h4').forEach(function(el){   // 장식용 이모지 제거(조잡함 방지)
    if(/[👏🎉🔥✨⭐🚀💥📌🎯🙌💪👍]/.test(el.textContent)) el.innerHTML=el.innerHTML.replace(/\s*(?:👏|🎉|🔥|✨|⭐|🚀|💥|📌|🎯|🙌|💪|👍)️?/g,'');
  });
}

function classify(el){
  const t=el.tagName;
  if(t==='PRE') return el.classList.contains('vega-card')||el.querySelector('code.language-vega-lite')?'fig':'code';
  if(t==='TABLE') return 'table';
  if(t==='BLOCKQUOTE') return 'note';
  if(t==='UL'||t==='OL') return 'p';
  if(t==='P') return el.querySelector('img')?'fig':'p';
  return 'skip';   // 제목(H*) 등은 하이라이트 대상 아님(문맥으로 스크롤만 됨)
}
function buildCueMap(cues){
  const slots=[...docEl.children].map(el=>({el,kind:classify(el)}));
  let ptr=0; const map=[];
  for(const c of cues){
    const want = c.type==='gate' ? 'note' : c.type;   // 게이트는 문서에서 인용구(blockquote)로 그려진다
    let found=null;
    for(let j=ptr;j<slots.length;j++){ if(slots[j].kind===want){ found=slots[j].el; ptr=j+1; break; } }
    map.push(found);
  }
  return map;
}
function setHl(idx){
  if(idx===curHl) return;
  if(curHl>=0&&curMap[curHl]) curMap[curHl].classList.remove('hl');
  curHl=idx;
  const el=curMap[idx];
  if(el){ el.classList.add('hl'); el.scrollIntoView({behavior:'smooth', block:'center'}); }
}
function syncHl(){
  if(!curCues.length) return;
  let idx=-1;
  for(let j=0;j<curCues.length;j++){ if(curCues[j].start<=audio.currentTime+0.02) idx=j; else break; }
  if(idx<0) return;
  // 게이트 자동 멈춤: 방금 게이트(질문) 청크가 끝나 다음 청크(답)로 넘어가려는 순간, 한 번만 멈춘다
  if(idx>=1 && curCues[idx-1] && curCues[idx-1].type==='gate' && !pausedGates.has(idx-1)){
    pausedGates.add(idx-1);
    if(!audio.paused) audio.pause();
    setHl(idx-1);                 // 떠올리는 동안 시선은 질문(게이트)에 머문다
    gatehint.classList.add('show');
    return;
  }
  setHl(idx);
}

function buildNav(){
  S.forEach(function(s,i){
    var b=document.createElement('button'); b.className='navrow';
    b.innerHTML='<span class="nn">'+esc(s.nn)+'</span><span class="nt">'+esc(s.title)+'</span>';
    b.onclick=function(){ this.blur(); select(i,true); };
    navEl.appendChild(b); rows.push(b);
  });
}
// 활성 섹션 아래에 그 문서의 H2 목차를 펼친다(스크롤 추적)
function renderSubTOC(i){
  var old=navEl.querySelector('.subtoc'); if(old) old.remove();
  subHeads=[].slice.call(docEl.querySelectorAll('h2')); subLinks=[];
  if(!subHeads.length) return;
  var box=document.createElement('div'); box.className='subtoc';
  subHeads.forEach(function(h,j){
    h.id='h'+j;
    var a=document.createElement('a'); a.className='sublink'; a.textContent=h.textContent; a.href='#h'+j;
    a.onclick=function(e){ e.preventDefault(); h.scrollIntoView({behavior:'smooth', block:'start'}); var sd=document.getElementById('side'); if(sd) sd.classList.remove('open'); };
    box.appendChild(a); subLinks.push(a);
  });
  if(rows[i]) rows[i].insertAdjacentElement('afterend', box);
}
function spy(){
  var de=document.documentElement, denom=(de.scrollHeight-de.clientHeight)||1;
  progEl.style.width=(de.scrollTop/denom*100)+'%';
  if(subHeads.length){ var c=0; subHeads.forEach(function(h,j){ if(h.getBoundingClientRect().top<150) c=j; });
    subLinks.forEach(function(l,j){ l.classList.toggle('on',j===c); }); }
}
window.addEventListener('scroll', spy, {passive:true});

function select(i, play){
  if(i<0||i>=S.length) return;
  docEl.querySelectorAll('pre.vega-card').forEach(function(pre){ if(pre._vegaFinalize) try{pre._vegaFinalize();}catch(e){} });
  cur=i; var s=S[i];
  docEl.innerHTML=md(s.doc);
  if(s.warnings&&s.warnings.length){
    var warning=document.createElement('div'); warning.className='audio-warning'; warning.setAttribute('role','status');
    warning.textContent='이 문서의 낭독 '+s.warnings.length+'곳이 생성되지 않아 짧은 무음으로 남았습니다. 자세한 기록은 audio/render-warnings.json에 있습니다.';
    docEl.prepend(warning);
  }
  enhanceDoc();
  scriptEl.textContent=s.script||'(스크립트 없음)';
  curCues=s.cues||[]; curMap=buildCueMap(curCues); curHl=-1; pausedGates=new Set(); gatehint.classList.remove('show');
  audioReady=!!s.audio;
  if(audioReady) audio.src=s.audio;
  else{ audio.removeAttribute('src'); audio.load(); }
  audio.playbackRate=parseFloat(speedSel.value);
  ppBtn.disabled=!audioReady; seek.disabled=!audioReady; speedSel.disabled=!audioReady;
  barEl.classList.toggle('audio-pending',!audioReady);
  timeEl.textContent=audioReady?'0:00 / 0:00':'음성 준비 중 · 본문은 바로 읽을 수 있습니다';
  curLabel.textContent=s.nn+' · '+s.title;
  rows.forEach(function(r,j){ r.classList.toggle('active',j===i); });
  renderSubTOC(i);
  window.scrollTo(0,0);
  var side=document.getElementById('side'); if(side) side.classList.remove('open');
  spy(); syncHl();
  if(play&&s.audio){ audio.play().catch(function(){}); }
}
function stepSpeed(d){ var idx=SPEEDS.indexOf(parseFloat(speedSel.value)); if(idx<0)idx=1;
  idx=Math.max(0,Math.min(SPEEDS.length-1,idx+d)); speedSel.value=String(SPEEDS[idx]); audio.playbackRate=SPEEDS[idx]; }

ppBtn.onclick=function(){ this.blur(); if(!audioReady) return; if(audio.paused)audio.play(); else audio.pause(); };
document.getElementById('prev').onclick=function(){ this.blur(); select(cur-1,true); };
document.getElementById('next').onclick=function(){ this.blur(); select(cur+1,true); };
audio.onplay=function(){ ppBtn.textContent='⏸'; gatehint.classList.remove('show'); docEl.classList.add('playing'); };
audio.onpause=function(){ ppBtn.textContent='▶︎'; docEl.classList.remove('playing'); };   // 멈추면 전부 정상으로
audio.onended=function(){ if(cur<S.length-1) select(cur+1,true); else docEl.classList.remove('playing'); };
audio.ontimeupdate=function(){ if(audio.duration){ seek.value=String((audio.currentTime/audio.duration*1000)||0);
  timeEl.textContent=fmt(audio.currentTime)+' / '+fmt(audio.duration); } syncHl(); };
audio.onloadedmetadata=function(){ timeEl.textContent='0:00 / '+fmt(audio.duration); };
seek.oninput=function(){ if(audio.duration) audio.currentTime=seek.value/1000*audio.duration; };
speedSel.onchange=function(){ audio.playbackRate=parseFloat(speedSel.value); };
// 본문 폭 조절(−/+): localStorage에 저장해 다음 열람에도 유지
var COLW=[640,720,800,880,960,1080,1200,1360], colw=720;
try{ colw=parseInt(localStorage.getItem('learnColW'),10)||720; }catch(e){}
if(COLW.indexOf(colw)<0) colw=720;
function applyColW(){ document.documentElement.style.setProperty('--colw', colw+'px');
  var el=document.getElementById('wval'); if(el) el.textContent=(colw===720)?'기본':colw+'px';
  try{ localStorage.setItem('learnColW',String(colw)); }catch(e){} }
applyColW();
document.getElementById('wnarrow').onclick=function(){ this.blur(); var i=COLW.indexOf(colw); if(i>0){ colw=COLW[i-1]; applyColW(); } };
document.getElementById('wwide').onclick=function(){ this.blur(); var i=COLW.indexOf(colw); if(i<COLW.length-1){ colw=COLW[i+1]; applyColW(); } };
// 스페이스: 짧게 탭=재생/정지, 길게 누르면=2배속(떼면 선택된 배속으로 복귀)
let spaceHeld=false, holdEngaged=false, holdTimer=null;
function editing(t){ return t==='INPUT'||t==='SELECT'||t==='TEXTAREA'; }
document.addEventListener('keydown',function(e){
  if(editing(e.target.tagName)) return;
  if(e.code==='Space'){
    e.preventDefault();
    if(!audioReady) return;
    if(e.repeat) return;
    spaceHeld=true;
    holdTimer=setTimeout(function(){ if(spaceHeld){ holdEngaged=true; if(audio.paused) audio.play().catch(function(){}); audio.playbackRate=2; ffind.classList.add('show'); } }, 180);
    return;
  }
  if(e.key==='ArrowRight'){ e.preventDefault(); audio.currentTime=Math.min(audio.duration||0,audio.currentTime+5); }
  else if(e.key==='ArrowLeft'){ e.preventDefault(); audio.currentTime=Math.max(0,audio.currentTime-5); }
  else if(e.key==='ArrowUp'){ e.preventDefault(); stepSpeed(1); }
  else if(e.key==='ArrowDown'){ e.preventDefault(); stepSpeed(-1); }
  else if(e.key==='n'||e.key==='j'){ select(cur+1,true); }
  else if(e.key==='p'||e.key==='k'){ select(cur-1,true); }
});
document.addEventListener('keyup',function(e){
  if(e.code!=='Space') return;
  if(editing(e.target.tagName)) return;
  e.preventDefault();
  spaceHeld=false; clearTimeout(holdTimer);
  if(holdEngaged){ holdEngaged=false; audio.playbackRate=parseFloat(speedSel.value); ffind.classList.remove('show'); }
  else if(audioReady){ audio.paused?audio.play():audio.pause(); }   // 짧은 탭
});
var _nt=document.getElementById('navtoggle'); if(_nt) _nt.onclick=function(){ this.blur(); var sd=document.getElementById('side'); if(sd) sd.classList.toggle('open'); };
// 재생 중 주변 흐림 토글 (기본 켜짐, 선택은 브라우저에 기억)
var dimBtn=document.getElementById('dimtoggle');
var dimOn=true; try{ dimOn = localStorage.getItem('learn.focusdim')!=='off'; }catch(e){}
function applyDim(){ docEl.classList.toggle('dimoff', !dimOn); if(dimBtn){ dimBtn.classList.toggle('on', dimOn); dimBtn.textContent = dimOn?'흐림 켬':'흐림 끔'; } }
if(dimBtn) dimBtn.onclick=function(){ this.blur(); dimOn=!dimOn; try{ localStorage.setItem('learn.focusdim', dimOn?'on':'off'); }catch(e){} applyDim(); };
applyDim();
buildNav(); select(Math.max(0,Math.min(S.length-1,INITIAL)),false);
</script>
<script src="assets/anim.bundle.js"></script>
<script>
/* 동적 시각 트랙 — 한 주제 번들이 window.LearnAnim·window.LearnSim을 선택적으로 노출한다.
   .anim. 포스터는 Remotion Player로, .sim. 포스터는 React 시뮬레이션으로 승격한다.
   번들이 없거나 등록 이름이 없으면 포스터 이미지 그대로 남는다. */
(function(){
  var st=document.createElement('style');
  st.textContent='#doc p.visual-live{border:1px solid var(--line);border-radius:14px;padding:10px;background:#fff;margin:1.6em 0}'+
    '#doc p.visual-live>img{display:none}'+
    '#doc p.visual-live .anim-host,#doc p.visual-live .sim-host{border-radius:9px;overflow:hidden}'+
    '#doc p.visual-live .visual-cap{font-size:12.5px;color:var(--faint);padding:8px 6px 2px;text-align:center}'+
    '#doc p.sim-live .sim-tools{display:flex;align-items:center;justify-content:space-between;gap:10px;padding:8px 4px 2px}'+
    '#doc p.sim-live .sim-mode{font-size:12px;color:var(--faint)}'+
    '#doc p.sim-live .sim-reset{border:1px solid var(--line);background:var(--paper);color:var(--soft);border-radius:7px;padding:5px 10px;font:inherit;font-size:12px;cursor:pointer}'+
    '#doc p.sim-live .sim-reset:hover{background:var(--accent-soft);color:var(--accent)}'+
    '#doc p.sim-live .sim-reset:disabled{cursor:not-allowed;opacity:.48;background:var(--paper);color:var(--faint)}';
  document.head.appendChild(st);

  function addCaption(p,img,fallback){
    var cap=document.createElement('div'); cap.className='visual-cap';
    cap.textContent=img.getAttribute('alt')||fallback; p.appendChild(cap);
  }
  function mountAnimations(){
    if(!window.LearnAnim) return;
    docEl.querySelectorAll('p > img[src*=".anim."]').forEach(function(img){
      var p=img.parentElement;
      if(p.dataset.animMounted) return;
      p.dataset.animMounted='1';
      var name=(img.getAttribute('src').split('/').pop()||'').split('.anim.')[0];
      var host=document.createElement('div'); host.className='anim-host';
      p.appendChild(host);
      var ctl=LearnAnim.mount(host,name);
      if(!ctl){ p.removeChild(host); return; }   // 번들에 없는 컴포지션이면 포스터로 남긴다
      p.classList.add('visual-live','anim-live'); p._anim=ctl;
      addCaption(p,img,'애니메이션');
    });
  }
  function mountSimulations(){
    if(!window.LearnSim) return;
    docEl.querySelectorAll('p > img[src*=".sim."]').forEach(function(img){
      var p=img.parentElement;
      if(p.dataset.simMounted) return;
      p.dataset.simMounted='1';
      var name=(img.getAttribute('src').split('/').pop()||'').split('.sim.')[0];
      var host=document.createElement('div'); host.className='sim-host';
      p.appendChild(host);
      var ctl=LearnSim.mount(host,name);
      if(!ctl){ p.removeChild(host); return; }
      p.classList.add('visual-live','sim-live'); p._sim=ctl;
      var tools=document.createElement('div'); tools.className='sim-tools';
      var mode=document.createElement('span'); mode.className='sim-mode'; mode.setAttribute('aria-live','polite'); mode.textContent='직접 조작';
      var reset=document.createElement('button'); reset.type='button'; reset.className='sim-reset'; reset.textContent='초기화';
      reset.onclick=function(){ this.blur(); ctl.reset(); };
      tools.appendChild(mode); tools.appendChild(reset); p.appendChild(tools); p._simMode=mode;
      p._simReset=reset;
      addCaption(p,img,'시뮬레이션');
    });
  }
  function mountAll(){ mountAnimations(); mountSimulations(); }

  function cueDurationAt(idx){
    var cue=curCues[idx]||{};
    if(Number.isFinite(cue.duration)&&cue.duration>0) return cue.duration;
    var next=curCues[idx+1];
    if(next&&Number.isFinite(next.start)) return Math.max(.001,next.start-(cue.start||0));
    if(Number.isFinite(audio.duration)) return Math.max(.001,audio.duration-(cue.start||0));
    return .001;
  }
  function cueStages(cue){ return cue?(cue.stages||cue.anim||[]):[]; }
  function syncActiveVisual(){
    if(curHl<0) return;
    var el=curMap[curHl], cue=curCues[curHl];
    if(!el||!cue) return;
    var local=Math.max(0,audio.currentTime-(cue.start||0));
    var duration=cueDurationAt(curHl);
    var stages=cueStages(cue);
    if(el._anim&&typeof el._anim.sync==='function') el._anim.sync(local,duration,stages);
    if(el._sim&&typeof el._sim.sync==='function'){
      var guided=!audio.paused&&!audio.ended;
      el._sim.sync(local,duration,stages,guided);
      if(el._simMode) el._simMode.textContent=guided?'나레이션 안내 중':'직접 조작';
      if(el._simReset) el._simReset.disabled=guided;
    }
  }

  // 하이라이트가 동적 시각 블록에 들어서면 같은 음성 시각으로 맞춘다.
  // 예전 애니메이션 번들은 sync()가 없으면 restart()로 후퇴한다.
  var _setHl=setHl;
  setHl=function(idx){
    var prev=(curHl>=0)?curMap[curHl]:null;
    _setHl(idx);
    var next=(idx>=0)?curMap[idx]:null;
    if(prev&&prev!==next&&prev._anim) prev._anim.pause();
    if(prev&&prev!==next&&prev._sim){
      prev._sim.setNarrationActive(false,false);
      if(prev._simMode) prev._simMode.textContent='직접 조작';
      if(prev._simReset) prev._simReset.disabled=false;
    }
    if(next&&next!==prev&&next._anim){
      if(typeof next._anim.sync==='function') syncActiveVisual();
      else next._anim.restart();
    }
    if(next&&next!==prev&&next._sim) syncActiveVisual();
  };

  // 섹션을 다시 그리면 기존 React 시뮬레이션을 정리하고 동적 시각을 다시 심는다.
  var _select=select;
  select=function(i,play){
    docEl.querySelectorAll('p.sim-live').forEach(function(p){ if(p._sim&&p._sim.unmount) p._sim.unmount(); });
    _select(i,play); mountAll();
  };

  // HTML audio가 유일한 시계다. 재생·탐색·배속 중 매 프레임 audio.currentTime을
  // Remotion 프레임과 시뮬레이션 안내 단계에 함께 전달한다.
  var visualRaf=0;
  function stopVisualClock(){ if(visualRaf){ cancelAnimationFrame(visualRaf); visualRaf=0; } }
  function tickVisualClock(){
    visualRaf=0;
    syncHl();
    syncActiveVisual();
    if(!audio.paused&&!audio.ended) visualRaf=requestAnimationFrame(tickVisualClock);
  }
  function startVisualClock(){
    if(!visualRaf&&!audio.paused) visualRaf=requestAnimationFrame(tickVisualClock);
  }
  audio.addEventListener('pause',function(){
    stopVisualClock(); syncActiveVisual();
    curMap.forEach(function(el){ if(el&&el._anim) el._anim.pause(); });
  });
  audio.addEventListener('play',function(){
    var el=(curHl>=0)?curMap[curHl]:null;
    if(el&&el._anim&&typeof el._anim.sync!=='function'&&!el._anim.isPlaying()) el._anim.play();
    syncActiveVisual(); startVisualClock();
  });
  audio.addEventListener('seeking',function(){ syncHl(); syncActiveVisual(); });
  audio.addEventListener('seeked',function(){ syncHl(); syncActiveVisual(); });
  audio.addEventListener('ended',function(){
    stopVisualClock(); syncActiveVisual();
    curMap.forEach(function(el){ if(el&&el._anim) el._anim.pause(); });
  });
  seek.addEventListener('input',function(){ syncHl(); syncActiveVisual(); });

  mountAll();
})();
</script>
</body>
</html>
'''

def render_player(secs, initial=0):
    dj = json.dumps(secs, ensure_ascii=False).replace('</', '<\\/')
    return (TEMPLATE
            .replace('__TITLE__', html.escape(secs[initial]['title']))
            .replace('__POINT__', html.escape(point_name))
            .replace('/*__MARKED__*/', marked_js)
            .replace('/*__DATA__*/', dj)
            .replace('__INITIAL__', str(initial)))

# 기본: 섹션당 하나의 player(<NN-슬러그>.player.html). LEARN_PLAYER=point면 전 섹션 통합 player.html.
mode = os.environ.get('LEARN_PLAYER', 'section')
if mode == 'point':
    with open(os.path.join(artifact_root, 'player.html'), 'w', encoding='utf-8') as f:
        f.write(render_player(sections, 0))
    print('준비: player.html  (통합, 섹션 %d개)' % len(sections))
else:
    names = []
    for index, s in enumerate(sections):
        fn = s['stem'] + '.player.html'
        with open(os.path.join(artifact_root, fn), 'w', encoding='utf-8') as f:
            # 각 챕터 파일은 자기 문서에서 열리되, 좌측 메뉴에는 현재 완성된
            # 모든 챕터를 넣는다. 새 문서 뒤 재생성하면 앞 파일의 메뉴도 갱신된다.
            f.write(render_player(sections, index))
        names.append(fn)
    print('준비: 섹션별 player %d개: %s' % (len(sections), ', '.join(names)))
PY

# 완성된 스테이징 산출물을 검증한 뒤에만 공개 경로로 교체한다.
if command -v node >/dev/null 2>&1; then
  node "$SKILL_DIR/scripts/verify-align.js" "$FOLDER" "$stage" || true
  node "$SKILL_DIR/scripts/lint-doc.js" "$FOLDER" || true
else
  echo "(node 없음 — 하이라이트 정렬 검증 건너뜀)"
fi

staged_players=( "$stage"/*.player.html "$stage"/player.html )
player_count=0
for player in "${staged_players[@]}"; do
  [ ! -f "$player" ] || player_count=$((player_count+1))
done
[ "$player_count" -gt 0 ] || { echo "생성된 player 파일이 없습니다." >&2; exit 1; }

[ ! -e "$FOLDER/audio" ] || [ -d "$FOLDER/audio" ] || {
  echo "audio 경로가 디렉터리가 아닙니다: $FOLDER/audio" >&2
  exit 1
}
for player in "${staged_players[@]}"; do
  [ -f "$player" ] || continue
  mv -f "$player" "$FOLDER/$(basename "$player")"
done

old_audio="$stage/.old-audio"
if [ "$TEXT_ONLY" != 1 ]; then
  if [ -d "$FOLDER/audio" ]; then
    mv "$FOLDER/audio" "$old_audio"
  fi
  if ! mv "$stage/audio" "$FOLDER/audio"; then
    [ ! -d "$old_audio" ] || mv "$old_audio" "$FOLDER/audio"
    echo "완성된 audio 산출물 교체에 실패했습니다." >&2
    exit 1
  fi
  echo "완료: $FOLDER/audio 및 player 파일을 함께 갱신했습니다."
else
  echo "완료: 음성은 건드리지 않고 읽기용 player와 챕터 메뉴를 갱신했습니다."
fi
