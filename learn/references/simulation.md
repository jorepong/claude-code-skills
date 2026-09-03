# 인터랙티브 시뮬레이션 — 조건을 바꾸며 인과를 직접 확인한다

시각 커버리지 지도에서 학습자가 **입력·조건·정책을 바꾸고 결과 차이를 비교해야 이해되는 역할**을 발견하면 인터랙티브 시뮬레이션으로 만든다. 매체 선택의 정본은 `visuals.md`이며, 이 문서는 선택된 시뮬레이션을 player.html 안에서 실제로 동작시키는 작법과 계약을 다룬다.

고정된 한 흐름을 관찰하는 일은 Remotion 애니메이션이 낫다. 반대로 패킷 손실률, 동시 실행 수, 캐시 크기, 알고리즘 입력처럼 **원인을 조작해 결과가 달라지는 것 자체가 학습 내용**이면 정해진 영상으로 대신하지 않는다. 같은 메커니즘을 여러 조건에서 직접 시험하게 한다.

## 학습 경험 설계

먼저 이 시뮬레이션이 답하게 할 질문 하나를 정한다. 예를 들면 “손실률이 오르면 재전송과 완료 시간은 어떻게 변하는가”다. 입력과 출력은 그 질문에 필요한 것만 둔다. 대시보드를 크게 만드는 것이 목적이 아니며, 서로 다른 질문은 여러 시뮬레이션으로 나눈다.

- 조작값에는 라벨·현재 값·의미 있는 범위를 함께 보여 준다. 슬라이더만 덩그러니 두지 않는다.
- 결과는 숫자 하나보다 변화의 방향과 원인이 읽히게 표현한다. 상태 도식, 작은 차트, 대기열, 단계 로그 등 내용에 맞는 형태를 고른다.
- `한 단계`, `실행/정지`, 입력 컨트롤처럼 메커니즘에 고유한 조작은 컴포넌트 안에 둔다. 공통 `초기화` 버튼은 player가 자동으로 붙인다.
- 확률이 들어가면 기본 실행은 고정 시드로 재현 가능하게 한다. 새 표본이 학습 역할을 가질 때만 명시적인 “다시 추첨” 조작으로 시드를 바꾼다.
- 네트워크 요청·현재 시각·렌더 순서에 결과를 맡기지 않는다. 같은 입력·시드에는 같은 결과가 나와야 한다.
- 키보드로 모든 입력을 조작할 수 있게 하고 `label`, `button`, `aria-live` 등 기본 접근성을 지킨다. 색만으로 상태를 구분하지 않는다.
- 기본 본문 폭과 모바일 폭에서 읽혀야 한다. 절대 좌표로 UI를 고정하기보다 grid·flex·wrap을 사용하고, 좁아지면 열이 자연스럽게 쌓이게 한다.

## 주제 번들에 등록한다

시뮬레이션도 애니메이션과 같은 `~/.claude/learn/.remotion/src/<YYYY-MM-DD>-<주제-슬러그>/`에 React 컴포넌트로 둔다. 날짜가 붙은 산출물 주제 폴더명과 같은 식별자를 사용하며, 별도 앱이나 서버를 만들지 않는다. 같은 `index.jsx`에서 `registerSimulations()`로 등록하면 기존 `build.sh`가 `assets/anim.bundle.js` 하나에 함께 묶는다.

```jsx
import React, {useEffect, useMemo, useState} from 'react';

export const STAGES = ['baseline', 'lossy', 'recovered'];

export const PacketLossLab = ({learnNarration}) => {
  const [loss, setLoss] = useState(0);
  const [retries, setRetries] = useState(true);

  useEffect(() => {
    if (!learnNarration?.active || !learnNarration.playing) return;
    const presets = {
      baseline: [0, true],
      lossy: [35, false],
      recovered: [35, true],
    };
    const preset = presets[learnNarration.stage];
    if (preset) {
      setLoss(preset[0]);
      setRetries(preset[1]);
    }
  }, [learnNarration?.active, learnNarration?.playing, learnNarration?.stage]);

  const delivered = useMemo(
    () => Math.round(100 * (1 - loss / 100) + (retries ? loss * 0.8 : 0)),
    [loss, retries],
  );

  return (
    <section style={{padding: 24}} aria-label="패킷 손실 시뮬레이션">
      <label>
        손실률 {loss}%
        <input type="range" min="0" max="60" value={loss}
          disabled={learnNarration?.active && learnNarration.playing}
          onChange={(event) => setLoss(Number(event.target.value))} />
      </label>
      <button type="button"
        disabled={learnNarration?.active && learnNarration.playing}
        onClick={() => setRetries((value) => !value)}>
        재전송 {retries ? '켬' : '끔'}
      </button>
      <output aria-live="polite">전달된 패킷 {delivered}/100</output>
    </section>
  );
};
```

```jsx
import {register, registerSimulations} from '../lib/register.jsx';
import {PacketLossLab, STAGES} from './PacketLossLab.jsx';

register({
  // 같은 주제의 Remotion 컴포지션들
});

registerSimulations({
  PacketLossLab: {
    component: PacketLossLab,
    height: 460,
    stages: STAGES,
  },
});
```

등록 이름은 영문자·숫자·하이픈·밑줄만 사용한다. `height`는 임베드 영역의 최소 높이이며 240 이상으로 둔다. `stages`는 선택 사항이지만, 나레이션 안내 단계가 있다면 중복 없는 stage ID 배열로 등록한다.

런타임은 컴포넌트에 `learnNarration`을 전달한다. 값은 `{active, playing, localSeconds, duration, progress, stage}`다. `active && playing`일 때만 stage에 맞는 대표 프리셋을 보여 주고 입력을 잠그는 것이 기본이다. 음성을 멈추면 같은 화면에서 학습자가 자유롭게 조작할 수 있다. 나레이션과 무관한 시뮬레이션은 이 prop을 사용하지 않아도 된다.

## 문서와 낭독에 연결한다

문서에는 애니메이션과 같은 포스터 문단을 쓰되 파일명에 `.sim.`을 둔다.

```markdown
![손실률과 재전송 정책에 따른 전달 결과를 비교하는 시뮬레이션](assets/PacketLossLab.sim.poster.svg)
```

player는 `.sim.` 앞의 이름으로 등록된 컴포넌트를 찾아 포스터를 실제 시뮬레이션으로 승격하고 공통 초기화 버튼을 붙인다. 나레이션 안내 중에는 입력과 초기화를 함께 잠그고, 일시정지하면 현재 상태를 유지한 채 둘 다 다시 연다. 번들이 없거나 등록 이름이 맞지 않으면 포스터가 그대로 남는다.

낭독에서는 같은 `@fig` 문단과 공용 `[[stage:<stage-id>]]` 마커를 사용한다.

```markdown
@fig [[stage:baseline]] 먼저 손실이 없는 기준 상태를 볼게요.
[[stage:lossy]] 이제 손실률은 높이고 재전송은 꺼 보겠습니다.
[[stage:recovered]] 같은 손실률에서 재전송을 켜면 전달량이 회복됩니다.
```

`narrate.sh`가 실제 발화 시작 시각을 cue의 `stages`에 보존한다. 나레이션 재생 중에는 해당 stage 프리셋을 안내하고, 일시정지하면 상태를 유지한 채 직접 조작 모드가 된다.

## 검증

기본 상태만 보고 끝내지 않는다. 최소값·최대값·대표 중간값, 모든 나레이션 stage, 실행·정지·한 단계가 있다면 각각의 상태, 극단값 뒤 초기화, 좁은 화면을 확인한다. 아래가 모두 맞아야 한다.

1. 같은 입력과 시드가 같은 결과를 만드는가.
2. 입력 하나를 바꿨을 때 출력 변화가 학습하려는 인과와 일치하는가.
3. 빠르게 연속 조작하거나 초기화해도 상태가 꼬이지 않는가.
4. 나레이션 재생 중 stage 프리셋이 문장과 맞고, 일시정지하면 직접 조작할 수 있는가.
5. 숫자·라벨·차트가 기본 player 폭과 모바일 폭에서 잘리거나 겹치지 않는가.
6. 포스터 폴백만 보아도 시뮬레이션이 다루는 질문을 이해할 수 있는가.

시뮬레이션의 결과가 실제 메커니즘과 다르면 화려한 UI보다 위험하다. 계산을 순수 함수로 분리해 입력·출력 사례를 먼저 검증하고, 그 뒤 UI와 나레이션 stage를 연결한다.
