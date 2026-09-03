# learn Remotion 실행 규약

이 문서는 learn 안에서 Remotion 참조를 적용하는 어댑터다. 다른 Remotion 참조와 내용이 충돌하면 이 문서를 우선한다. learn은 다른 스킬이나 별도 Remotion 프로젝트에 의존하지 않고, 자체 런타임 `~/.claude/learn/.remotion/`을 사용한다.

## 런타임 준비

런타임이 없거나 `remotion.sh`·`src/lib/learn-asset.js`가 없으면 learn 스킬의 설치 스크립트를 실행한다.

```bash
~/.claude/skills/learn/scripts/setup-remotion-runtime.sh
```

이 스크립트는 기존 `src/<YYYY-MM-DD>-<주제-슬러그>/`와 `public/<YYYY-MM-DD>-<주제-슬러그>/`를 보존하면서 관리 파일을 설치하고, 같은 버전의 React·Remotion·Player·CLI·media·layout-utils·esbuild 패키지를 준비한다.

`qa-stills.sh`도 함께 설치된다. 첫·중간·마지막을 포함한 기본 랜드마크와 지정 프레임을 일괄 렌더해 contact sheet로 묶으므로, 한 프레임만 보고 지나가 생기는 겹침 누락을 줄인다.

## 두 실행 모드

기본은 **학습 문서 임베드 모드**다. `src/<YYYY-MM-DD>-<주제-슬러그>/index.jsx`를 esbuild로 묶어 문서 폴더의 `assets/anim.bundle.js`로 만들고, `player.html`이 `.anim.` 포스터는 `<Player>`로, `.sim.` 포스터는 React 시뮬레이션으로 승격한다. 파일명은 기존 산출물과 호환하려고 유지하지만 애니메이션과 시뮬레이션을 함께 담는 동적 시각 번들이다. 애니메이션은 무음이며 음성은 바깥 낭독 트랙이 담당한다.

Studio 확인이나 MP4·WebM·정지 화면 내보내기는 필요할 때만 **CLI 모드**를 사용한다. 별도 프로젝트를 만들지 말고 같은 주제 소스에 대해 다음 래퍼를 실행한다.

```bash
R=~/.claude/learn/.remotion/remotion.sh
$R compositions <YYYY-MM-DD>-<주제-슬러그>
$R studio <YYYY-MM-DD>-<주제-슬러그>
$R still <YYYY-MM-DD>-<주제-슬러그> <컴포지션-ID> <출력.png> [Remotion 옵션]
$R render <YYYY-MM-DD>-<주제-슬러그> <컴포지션-ID> <출력.mp4> [Remotion 옵션]
```

`studio`는 장기 실행 프로세스다. 출력된 정확한 로컬 URL을 사용한다. 렌더는 사용자가 동영상이나 정지 화면 내보내기를 요청했을 때만 수행한다.

## 컴포지션 등록 계약

주제의 `index.jsx`는 Remotion 컴포지션에 learn 런타임의 `register()`를 호출한다. 같은 등록 정보가 임베드 Player와 CLI의 `<Composition>` 양쪽에 쓰인다. React 시뮬레이션은 같은 진입점에서 `registerSimulations()`로 등록해 임베드 번들에 함께 넣으며, Remotion CLI 컴포지션 목록에는 들어가지 않는다. 시뮬레이션의 구현 계약은 `../simulation.md`를 따른다.

```jsx
import {register} from '../lib/register.jsx';
import {MyComp, DURATION, FPS, WIDTH, HEIGHT, TIMELINE} from './MyComp.jsx';

register({
  MyComp: {
    component: MyComp,
    durationInFrames: DURATION,
    fps: FPS,
    width: WIDTH,
    height: HEIGHT,
    timeline: TIMELINE,
  },
});
```

등록 이름은 Remotion Composition ID가 되므로 영문자·숫자·하이픈·밑줄만 사용한다.

`durationInFrames`에는 전체 장면에 필요한 길이를 넣는다. 10초나 30초 같은 전체 길이 상한은 없다. 설명 단계가 많으면 필요한 만큼 늘리되, 하나의 컴포지션에 서로 다른 학습 역할을 억지로 합치지 말고 역할별 컴포지션으로 나눈다.

`timeline`은 낭독이 애니메이션의 의미 있는 장면을 정확히 찾도록 하는 선택 계약이다. 값은 해당 단계가 시작하는 컴포지션 프레임이며, 선언 순서대로 증가해야 한다.

```jsx
export const TIMELINE = {
  request: 0,
  serverWork: 72,
  response: 156,
};
```

짝이 되는 `@fig` 스크립트 문단에서는 같은 ID를 `[[stage:request]]`, `[[stage:serverWork]]`, `[[stage:response]]`처럼 넣는다. 마커는 낭독되지 않는다. 실제로 생성된 각 음성 조각의 시작 시각과 `TIMELINE` 프레임이 연결되므로, 문장 길이가 달라져도 장면 전환이 문장 경계에 맞는다. `timeline`이나 마커가 없으면 전체 낭독 길이에 맞춘 비례 재생으로 폴백한다.

## 로컬 자산 계약

learn 컴포지션에서는 `staticFile()`을 직접 호출하지 않는다. 로컬 HTML과 Remotion 개발 서버 양쪽에서 같은 소스가 작동하도록 `learnAsset()`을 사용한다.

1. 원본 자산을 `~/.claude/learn/.remotion/public/<YYYY-MM-DD>-<주제-슬러그>/` 아래에 둔다.
2. 컴포지션에서 날짜가 포함된 주제 식별자 경로를 `learnAsset()`에 넘긴다.
3. `build.sh`가 해당 자산을 문서 폴더의 `assets/<YYYY-MM-DD>-<주제-슬러그>/`로 함께 복사한다.

```jsx
import {Img} from 'remotion';
import {Video} from '@remotion/media';
import {learnAsset} from '../lib/learn-asset.js';

<Img src={learnAsset('2026-08-31-tcp-handshake/packet.png')} />
<Video src={learnAsset('2026-08-31-tcp-handshake/trace.mp4')} />
```

원격 `https:`, `data:`, `blob:` URL은 `learnAsset()`이 그대로 통과시킨다. `..`, 절대 경로, `public/` 접두사는 허용하지 않는다. CSS `url()`이나 `@font-face`에도 반환값을 사용할 수 있다.

## 패키지와 원본 참조의 명령 치환

추가 Remotion 패키지가 필요하면 런타임 래퍼를 사용해 모든 `remotion`·`@remotion/*` 버전을 맞춘다.

```bash
~/.claude/learn/.remotion/remotion.sh add @remotion/transitions
```

다른 참조에 나오는 일반 명령은 learn에서 다음처럼 해석한다.

- `npx remotion studio` → `remotion.sh studio <YYYY-MM-DD>-<주제-슬러그>`
- `npx remotion still` → `remotion.sh still <YYYY-MM-DD>-<주제-슬러그> ...`
- `npx remotion render` → `remotion.sh render <YYYY-MM-DD>-<주제-슬러그> ...`
- `npx remotion add <패키지>` → `remotion.sh add <패키지>`
- 새 프로젝트 scaffold → 사용하지 않고 자체 런타임과 등록 계약을 사용

## 음성·자막·편집성의 경계

일반 학습 애니메이션은 무음으로 유지하고 바깥 낭독과 동기화한다. 이때 HTML 오디오가 유일한 기준 시계다. 플레이어는 재생·일시정지·탐색 때마다 현재 낭독 위치를 컴포지션 프레임으로 환산해 `seekTo()` 하며, 낭독 중 Remotion 자체 반복 재생은 사용하지 않는다. 따라서 애니메이션 길이와 음성 길이가 달라도 두 개의 독립된 시계가 표류하지 않는다.

컴포지션 자체에 음성, 자막, 편집 가능한 영상 트랙을 넣는 것은 사용자가 독립 영상 내보내기를 요청했거나 그 기능 자체가 학습 내용일 때만 적용한다. 이 경우 `remotion-captions`, `remotion-multimedia`, `remotion-interactivity`, `remotion-render` 참조를 그대로 사용할 수 있다.

Studio에서 직접 편집할 가능성이 있으면 `Interactive.*`, 인라인 스타일, 인라인 `interpolate()` 규칙을 따른다. Player 전용 도식이라도 이 구조를 해치지 않는 범위에서는 같은 규칙을 우선한다.
