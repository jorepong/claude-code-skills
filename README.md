# claude-code-skills

[Claude Code](https://claude.com/claude-code)에서 제가 직접 만들어 실제로 매일 쓰고 있는 **에이전트 스킬(Agent Skill)** 모음입니다.

각 스킬은 특정 작업(지침 작성, 심층 학습, 웹 크롤링, 글쓰기)에서 LLM이 더 잘 동작하도록 설계한 지침 패키지입니다. 단순히 "이렇게 해라"를 나열한 프롬프트가 아니라, **왜 그렇게 동작해야 하는지(의도)와 그 근거**를 담아, 처음 보는 상황에서도 모델이 의도에 맞게 판단하도록 만드는 데 초점을 뒀습니다.

## 스킬이란

Claude Code의 [Agent Skill](https://docs.claude.com/en/docs/claude-code/skills)은 `SKILL.md`(진입 지침)와 선택적 `references/`(깊은 근거·세부 절차)로 이뤄진 폴더입니다. 사용자의 요청이 스킬의 `description`과 맞으면 Claude가 해당 스킬을 불러와 그 지침대로 작업합니다.

## 스킬 목록

| 스킬 | 하는 일 | 핵심 설계 |
|------|---------|-----------|
| **[instructify](./instructify)** | AI 에이전트 지침·프롬프트·시스템 프롬프트·`CLAUDE.md`·스킬 지침을 작성·개선한다. | 요청을 명령문으로 옮기기 전에 **의도**를 먼저 파악하고, LLM의 유연성을 죽이지 않는 지침을 쓴다. '계약(변형=버그)'과 '행동 공간(유연성=가치)'을 구분한다. |
| **[learn](./learn)** | 어떤 주제·개념이든 1:1 튜터식으로 깊게 학습한다(가볍게~무겁게 강도 조절). | 설명 문서·연습문제·시각 자료를 만들어 **개념 학습**과 **구현 장악**(직접 만들며 익히기)을 함께 진행한다. 학습자 프로필에 맞춰 깊이를 조율한다. |
| **[master-crawler](./master-crawler)** | 웹사이트를 분석하고 봇 탐지 우회를 포함한 크롤링 전략을 수립한다. | 정찰 → 봇 탐지 식별 → 우회 → 데이터 추출의 실전 방법론. 순서대로 밟는 절차가 아니라 **막혔을 때 꺼내 보는 참고서**로 설계했다. |
| **[postify](./postify)** | 어떤 소재든 그 자체로 완결된, 블로그·포트폴리오 수준의 마크다운 글로 만든다. | 세션 맥락 없이도 읽히는 **독립성**을 절대 원칙으로 두고, 구조·분류·편수를 소재에 맞춰 자율적으로 판단한다. |

## 설계 원칙

이 스킬들을 관통하는 공통된 생각이 하나 있습니다.

> **지침은 응답을 좁히는 도구가 아니라, 방향을 맞추되 합성은 LLM에 맡기는 도구다.**

동작 하나하나를 못박으면 그 하나는 잘 하지만 새로운 상황에서는 무너집니다. 그래서 각 스킬은 "무엇을 하라"보다 "왜 그렇게 하는가(의도)"와 그 트레이드오프를 적고, 변형이 곧 버그인 영역(출력 형식·안전 경계 등)만 절차로 고정합니다. 이 관점 자체를 도구로 만든 것이 `instructify`입니다.

## 설치 / 사용법

Claude Code는 `~/.claude/skills/` 아래의 스킬을 자동으로 인식합니다. 이 레포의 스킬을 쓰려면 원하는 스킬 폴더를 그 위치에 두면 됩니다.

```bash
# 레포 클론
git clone https://github.com/jorepong/claude-code-skills.git
cd claude-code-skills

# 방법 1) 심볼릭 링크 — 레포를 단일 원본으로 두고 링크만 건다 (권장)
ln -s "$(pwd)/instructify" ~/.claude/skills/instructify
ln -s "$(pwd)/postify"     ~/.claude/skills/postify
# 필요한 스킬만 골라 링크

# 방법 2) 복사 — 그냥 폴더째 복사
cp -r instructify ~/.claude/skills/
```

링크를 걸면 레포에서 스킬을 수정할 때마다 Claude Code에 바로 반영됩니다.

설치 후 Claude Code에서 슬래시 명령(`/instructify`, `/learn`, `/master-crawler`, `/postify`)으로 부르거나, 요청 내용이 스킬 `description`과 맞으면 Claude가 자동으로 불러옵니다.

## 라이선스

[MIT](./LICENSE)
