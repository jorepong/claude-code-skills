# 애니메이션 트랙 — Remotion으로 '움직이는 시각'을 문서에 심는다

학습 문서에서 **정해진 시간 흐름을 관찰하는 것** — 데이터가 흐르고, 상태가 바뀌고, 알고리즘이 한 단계씩 실행되고, 요청이 왕복하고, 값의 증가·감소 규칙이 시간에 따라 드러나는 과정 — 은 Remotion 애니메이션으로 만든다. 무겁게 모드에서는 이것이 선택이 아니라 필수 커버리지다. 학습자가 입력·조건을 바꾸며 결과를 비교해야 하는 역할은 `simulation.md`의 인터랙티브 시뮬레이션을 쓴다. 매체 선택은 `visuals.md`가 정본이다. 완성된 애니메이션은 mp4가 아니라 **코드째 번들되어 player.html 안에 살아있는 Remotion Player로 심기며**, 낭독과 같은 시계를 따라가고 학습자가 직접 스크럽·전체화면으로 살펴볼 수 있다.

## 정책 — 아낌없이, 적극적으로

애니메이션은 정적 그림이 못 하는 방식으로 이해를 돕는다 — 순서·인과·이동을 글이 아니라 눈으로 겪게 한다. 그러므로 **남발을 걱정해 아끼지 않는다.** 다만 움직인다는 이유만으로 모두 애니메이션으로 만들지는 않는다. 저자가 정한 한 궤적을 관찰하는 역할이면 애니메이션, 학습자가 조건을 바꿔 여러 궤적을 비교하는 역할이면 시뮬레이션이다. 정적인 구조·비교는 Mermaid나 표가 더 낫다.

애니메이션 하나가 문서 전체를 대표할 필요는 없다. 서로 다른 메커니즘이나 장면을 한 컴포지션에 욱여넣지 말고 **학습 역할별로 여러 개의 단순한 애니메이션**을 만든다. 한 애니메이션 안에서도 장면이 여럿 필요하면 `<Sequence>`로 분리한다. 시각 수를 줄이려고 화면을 과밀하게 만드는 것은 금지한다.

**문서당 애니메이션 하나를 암묵적 상한으로 삼지 않는다.** 서로 독립된 시간 흐름이 둘이면 애니메이션도 둘일 수 있다. 예컨대 전체 상태 곡선을 보여 주는 애니메이션이 있어도, 그 곡선을 만들어 내는 미시적 단계(요청·응답, 큐 변화, 확인마다 창 증가)가 별도 학습 목표라면 짧은 애니메이션을 추가한다. 반대로 학습자가 여러 시점을 오래 나란히 비교해야 하는 역할은 정적 단계 도식을 함께 둔다.

시간 변화가 있는 H2를 정적 그림만으로 처리하려면, 정지 상태를 오래 비교하는 편이 학습에 더 낫다는 구체적 이유가 있어야 한다. 단순히 애니메이션 제작 시간이 더 든다는 이유로 정적 그림으로 낮추지 않는다.

## 파이프라인 (5단계)

### 1. 공용 작업 공간 확인

작업 공간은 **`~/.claude/learn/.remotion/`** 하나를 모든 주제가 공유한다. 없거나 관리 파일이 빠졌으면 learn에 포함된 설치 스크립트로 준비한다:

```bash
~/.claude/skills/learn/scripts/setup-remotion-runtime.sh
```

`src/lib/register.jsx`(공용 마운트 런타임)와 `build.sh`(번들 스크립트)는 learn 스킬 자체에 포함된다. 런타임이 없거나 관리 파일이 빠졌으면 `~/.claude/skills/learn/scripts/setup-remotion-runtime.sh`를 실행한다. 기존 주제 소스와 로컬 자산은 보존된다.

### 2. 컴포지션 작성

`src/<YYYY-MM-DD>-<주제-슬러그>/<컴포지션이름>.jsx`에 짓는다. 날짜가 붙은 산출물 폴더명과 같은 식별자를 사용한다. 먼저 learn 실행 환경의 차이를 설명하는 `remotion/learn-runtime.md`를 읽고, 이어서 `remotion/remotion-markup/REFERENCE.md`와 필요한 심화 문서(타이밍·전환·텍스트 강조 등)를 읽는다. 화면 설계 기본은 `remotion/remotion-create/video-layout.md`, API가 기억과 다르면 `remotion/remotion-docs/REFERENCE.md`를 따른다. 모든 참조는 learn 내부에 있으며 다른 스킬을 읽지 않는다.

핵심 규칙(참조의 요지 + learn 고유):

- **모든 움직임은 `useCurrentFrame()` + `interpolate()`로.** CSS `transition`/`animation`은 렌더에서 깨지므로 금지. `Easing.bezier`로 타이밍을 다듬고, `extrapolate*: 'clamp'`를 기본으로 건다.
- **`transform` 문자열 대신 `scale`·`translate`·`rotate` 개별 CSS 속성**을 쓰고, interpolate 호출은 style 안에 인라인으로 둔다.
- 파일 끝에서 **`FPS`·`WIDTH`·`HEIGHT`·`DURATION`을 export** 한다(임베드 계약이 이 값으로 Player를 구성한다). 기본 캔버스는 1280×720·30fps다. **전체 길이 상한은 없다.** 한 장면은 대체로 10~30초 안에 하나의 변화에 집중하되, 설명이 길면 여러 `<Sequence>`를 이어 전체 컴포지션을 나레이션에 필요한 만큼 늘린다. 낭독 중에는 반복 재생하지 않는다.
- **무음으로 짓는다.** 소리는 낭독 트랙의 몫이다.
- 로컬 이미지·영상·음성·폰트는 `public/<YYYY-MM-DD>-<주제-슬러그>/`에 두고 `src/lib/learn-asset.js`의 `learnAsset()`으로 참조한다. `staticFile()` 직접 호출은 로컬 HTML에서 깨지므로 사용하지 않는다. `build.sh`가 문서의 `assets/<YYYY-MM-DD>-<주제-슬러그>/`로 함께 복사한다.
- **learn 종이 팔레트**로 문서와 한 벌로 보이게 한다: 배경 `#f6f1e7` · 카드 `#fffdf9` · 잉크 `#221f1a` · 보조 `#544c40` · 흐림 `#8b8173` · 테두리 `#e8dfcd` · 강조 `#b3541b` · 성공 `#3e7c4f` · 정보 `#2b6cb0` · 게이트 보라 `#6b4fb0`. 글꼴은 `'Pretendard', sans-serif`(플레이어 페이지가 로드해 준다), 코드는 모노스페이스.
- **한 번에 하나의 변화만.** 동시에 여러 요소가 움직이면 눈이 못 따라간다. 상단에 캡션 스트립을 두고 "지금 일어나는 일"을 구간별로 교차 페이드하면 낭독 없이 애니메이션만 봐도 따라올 수 있다.
- **원본 캔버스가 아니라 최종 player.html 크기로 설계한다.** 기본 본문 폭에서는 1280 캔버스가 약 절반으로 축소된다. 1280 기준으로 중심 제목 ≥72px, 주요 캡션 ≥48px, 구역 라벨·칩·코드 ≥36px, 보조 메타 ≥30px를 출발점으로 삼고 실제 임베드 화면에서 읽히는지 확인한다. 작은 글자로 내용을 욱여넣지 말고 장면이나 시각 자료를 나눈다.
- **안전 영역과 레이아웃 상자를 먼저 잡는다.** `remotion-create/video-layout.md`의 안전 영역을 따르고, 제목·정적 라벨·이동 요소마다 서로 침범하지 않는 상자를 정한다. 이동 경로가 정적 텍스트 상자를 지나지 않게 한다.
- **텍스트를 추측으로 배치하지 않는다.** 폰트를 먼저 로드한 뒤 `@remotion/layout-utils`의 `measureText()`·`fitText()`·`fillTextBox()`로 폭·줄 수·넘침을 확인한다(`remotion-markup/measuring-text.md`). 측정 속성과 렌더 속성은 같아야 한다. 글자가 길어지면 폰트를 읽을 수 없게 줄이는 대신 문구를 다듬거나 장면을 나눈다.
- 결정 장면 수가 많으면 장면을 `<Sequence>`로 나눈다(`remotion/remotion-markup/multi-scene-video.md`).

이동하는 요소(칩)는 `[frame, x, y]` 웨이포인트 목록을 interpolate로 잇는 패턴이 간결하다 — 기존 주제 폴더의 컴포지션(예: `src/js-event-loop/EventLoop.jsx`)을 견본으로 참고한다.

### 3. 진입점 등록 + 번들

`src/<YYYY-MM-DD>-<주제-슬러그>/index.jsx`:

```jsx
import {register} from '../lib/register.jsx';
import {MyComp, DURATION, FPS, WIDTH, HEIGHT, TIMELINE} from './MyComp.jsx';

register({
  MyComp: {
    component: MyComp, durationInFrames: DURATION, fps: FPS, width: WIDTH, height: HEIGHT,
    timeline: TIMELINE,
  },
  // 한 주제에 애니메이션이 여럿이면 여기 나란히 등록한다 (번들은 주제당 하나)
});
```

`TIMELINE`은 나레이션의 장면 마커와 맞물리는 **의미 단계 → 프레임** 지도다. 프레임은 선언 순서대로 증가해야 한다.

```jsx
export const TIMELINE = {
  intro: 0,
  addTransportHeader: 180,
  addNetworkHeader: 360,
  crossWire: 620,
  unwrap: 820,
};
```

```bash
~/.claude/learn/.remotion/build.sh <YYYY-MM-DD>-<주제-슬러그> <문서-폴더>
# → <문서-폴더>/assets/anim.bundle.js 생성 (수백 KB, 로컬 파일이라 부담 없음)
```

문서 폴더가 여러 개(포인트별)면 각 폴더에 대해 실행한다 — 같은 번들이 폴더마다 복사되어도 된다.

### 4. 문서에는 포스터 문단으로 넣는다

문서에서 애니메이션의 자리는 **포스터 이미지 문단**이다:

```markdown
![애니메이션의 요지 한 줄 — 캡션으로도 표시된다](assets/<컴포지션이름>.anim.poster.svg)
```

- 파일명 규약이 연결 고리다: `<컴포지션이름>.anim.*` → 플레이어 글루가 `.anim.` 앞 이름으로 번들의 컴포지션을 찾아 그 자리에 Player를 마운트한다.
- 포스터 SVG는 애니메이션의 정지 구도를 같은 팔레트로 그린 정적 미리보기다(재생 힌트 포함). 번들이 없거나 로드가 실패하면 이 포스터가 그대로 보이는 **자연 후퇴**가 되고, 낭독 1:1 정렬 검증(`verify-align.js`)도 이미지 문단으로 통과한다.
- 낭독 스크립트에서 이 문단은 **`@fig`로 태그**하고, 중계 방식은 `narration.md`의 애니메이션 항목을 따른다.

정확한 장면 싱크가 필요한 `@fig` 문단에는 동적 시각 공용 마커 `[[stage:<stage-id>]]`를 해당 설명 직전에 넣는다. `<stage-id>`는 컴포지션의 `TIMELINE` 키와 같아야 한다.

```markdown
@fig [[stage:intro]] 먼저 양쪽 컴퓨터를 볼게요.
[[stage:addTransportHeader]] 이제 전송 계층에서 헤더가 붙습니다.
[[stage:crossWire]] 완성된 프레임이 케이블을 건너가요.
[[stage:unwrap]] 받는 쪽에서는 반대로 헤더를 벗깁니다.
```

마커는 TTS에 전달되거나 스크립트 보기에 표시되지 않는다. `narrate.sh`가 마커별 실제 음성 시작 시각을 `cues.json`에 보존한다. 마커가 없으면 나레이션 블록의 시작과 끝에 맞춰 애니메이션 전체를 비례 재생한다. 개념의 세부 장면까지 맞춰야 하면 마커를 생략하지 않는다.

### 5. 읽기용 player와 낭독 player에 함께 붙는다

`build-players.sh <폴더>`가 먼저 만드는 읽기용 HTML과, 나중에 `narrate.sh <폴더>`가 음성을 결합한 HTML에는 같은 애니메이션 글루가 내장되어 있다. 별도 주입·후처리는 없다. 음성이 없을 때도 포스터가 Remotion Player로 승격되어 직접 스크럽할 수 있고, 음성이 붙은 뒤에는 아래처럼 동기화된다.

- **HTML 오디오가 유일한 기준 시계다.** 현재 `audio.currentTime`을 해당 `@fig` 블록의 로컬 시각으로 바꾸고, 마커의 실제 음성 오프셋과 `TIMELINE` 프레임 사이를 보간해 Remotion Player를 `seekTo()`한다.
- 일시정지·탐색·0.75~2배속에서도 애니메이션은 음성 시각을 그대로 따른다. 별도의 Remotion 시계를 동시에 흘리거나 낭독 중 반복 재생하지 않는다.
- 낭독이 멈춘 동안에는 Player 컨트롤로 애니메이션을 독립적으로 살펴볼 수 있다. 낭독을 다시 재생하면 즉시 음성 시각으로 돌아와 동기화된다. 스페이스 키는 낭독용으로 남겨 둔다.

## 검증

번들·문서·낭독까지 갖춘 뒤 헤드리스로 마운트를 확인한다:

```bash
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
"$CHROME" --headless=new --disable-gpu --dump-dom --virtual-time-budget=15000 \
  "file://<문서 폴더>/<NN-슬러그>.player.html" | grep -c "__remotion-player"   # 1 이상이면 마운트 성공
```

마운트 성공만으로 검증을 끝내지 않는다. **전체 타임라인의 다중 프레임 시각 QA가 필수다.**

1. `TIMELINE`의 모든 프레임, 각 인접 프레임의 중간, 이동 요소가 정적 요소에 가장 가까워지는 프레임, 첫 프레임과 마지막 프레임을 정지 화면으로 렌더한다. `qa-stills.sh`는 기본 랜드마크 5개와 추가로 넘긴 프레임을 한꺼번에 렌더하고 contact sheet를 만든다.

   ```bash
   ~/.claude/learn/.remotion/qa-stills.sh \
     <YYYY-MM-DD>-<주제-슬러그> <컴포지션-ID> <QA-출력-폴더> \
     <TIMELINE-프레임...> <충돌-위험-프레임...>
   ```
2. 원본 1280×720 정지 화면과 기본 폭의 실제 `player.html` 화면을 둘 다 본다. 원본에서 읽혀도 임베드 축소 뒤 작으면 실패다.
3. 제목·캡션 줄바꿈, 텍스트 넘침, 요소 겹침, 이동 경로 침범, 안전 영역 이탈을 모든 검사 프레임에서 확인한다.
4. 한 장면이 과밀하면 글자를 줄이지 말고 여러 장면이나 여러 애니메이션으로 나눈다.
5. 나레이션 렌더 뒤 `@fig` cue의 `duration`·`stages` 오프셋과 컴포지션 `TIMELINE` 키가 모두 대응하는지 확인하고, 플레이어에서 탐색·배속·일시정지를 직접 시험한다.

검사에서 문제가 보이면 좌표·장면 분할·타임라인을 고치고 다시 `build.sh`를 돌린다. 스크립트 문구나 `[[stage:...]]` 위치를 바꿨다면 `narrate.sh`도 다시 돌린다.

## 임베드 계약 (내부 구조 — 복원·확장 시에만 필요)

- `src/lib/register.jsx`의 `register(comps)`가 `window.LearnAnim.mount(el, 이름)`을 노출한다. mount는 반복을 끈 `<Player>`를 0프레임에 렌더하고 `{play, pause, seekTo, sync, isPlaying}` 컨트롤러를 돌려준다. `sync()`는 cue 시각과 `TIMELINE`을 프레임으로 변환한다.
- player.html의 글루(narrate.sh 템플릿 내장)는 `assets/anim.bundle.js`를 로드한 뒤 `p > img[src*=".anim."]`를 찾아 승격한다. 낭독 재생 중에는 `requestAnimationFrame`마다 오디오 시각을 읽어 활성 애니메이션의 `sync()`를 호출한다.

> **참고 — 강의 영상 내보내기.** 컴포지션·낭독 음성(mp3)·타이밍(cues.json)이 모두 갖춰지므로, 원하면 이들을 Remotion으로 조립해 한 편의 강의 영상(mp4)으로 렌더할 수 있다. 학습자가 요청할 때만 한다 — 기본 산출물은 어디까지나 문서 플레이어다.

Studio·정지 화면·동영상 렌더가 필요하면 `remotion/learn-runtime.md`의 `remotion.sh` 명령을 사용한다. 별도 Remotion 프로젝트를 만들지 않는다.
