#!/usr/bin/env bash
# 현재까지 완성된 학습 문서로 음성 없는 읽기용 player를 빠르게 다시 만든다.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEARN_TEXT_ONLY=1 exec "$SCRIPT_DIR/narrate.sh" "$@"
