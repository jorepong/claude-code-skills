---
name: master-crawler
description: Analyzes websites and builds crawling strategies with bot detection bypass. Use for crawling, scraping, bot detection bypass, API reverse engineering, or web analysis tasks.
argument-hint: [target URL or site description]
---

# Master Crawler — 웹 크롤링 & 봇 탐지 우회 종합 가이드

이 스킬은 어떤 웹사이트든 분석하고 크롤링 전략을 수립할 때 사용한다. 특정 사이트에 종속되지 않는 범용 방법론이며, 다양한 실전 경험에서 도출된 접근법과 시행착오의 교훈을 담고 있다.

대상 사이트: $ARGUMENTS

---

## 이 스킬을 사용하는 방법

**이 스킬은 순서대로 따라야 하는 절차가 아니다.**

아래의 Phase들은 크롤링 과정에서 막혔을 때 꺼내보는 참고서다. 문제가 생겼을 때 해당하는 Phase를 찾아 해결 실마리를 얻는 용도로 활용한다.

**경험 기반 직관이 있다면 그것을 먼저 시도하라.**

비슷한 사이트를 크롤링해본 경험, API 패턴에 대한 감각, 에러 메시지에서 오는 직관 — 이런 것들이 있다면 스킬의 절차를 거치지 않고 바로 시도하는 것이 더 빠르다. 스킬은 그 시도가 막혔을 때 다음 방향을 찾기 위한 도구다.

예를 들어:
- URL 변형을 몇 가지 떠올릴 수 있다면 바로 시도해보라. Phase 1을 정독할 필요 없다.
- 403이 떴고 TLS 문제일 것 같다는 감이 온다면 바로 `curl_cffi`를 써라. Phase 2~3을 거칠 필요 없다.
- 이미 비슷한 사이트에서 성공한 패턴이 있다면 그것부터 적용해라.

**스킬을 참조해야 할 때는 이럴 때다:**
- 직관적인 시도가 모두 실패하고 원인을 모를 때
- 처음 보는 봇 탐지 증상이 나타날 때
- 더 체계적인 접근이 필요하다고 판단될 때

---

## Phase 1: 타겟 사이트 정찰

대상 사이트를 분석하여 기술 스택과 보안 체계를 파악한다.

### 1.1 기술 스택 식별

1. 브라우저 개발자 도구(Network 탭, XHR 필터)로 페이지 로드 시 발생하는 요청을 관찰한다.
2. 다음 항목을 확인한다:
   - **프레임워크**: React/Next.js/Vue/Angular 등 (HTML 소스에서 `__NEXT_DATA__`, `__next_f` 등의 전역 변수 확인)
   - **렌더링 방식**: SSR(서버 사이드 렌더링) vs CSR(클라이언트 사이드 렌더링)
   - **API 엔드포인트**: XHR/Fetch 요청 URL 패턴 기록
   - **CDN/보안 솔루션**: 응답 헤더에서 `server`, `x-powered-by`, 에러 페이지의 도메인(`edgesuite.net`→Akamai, `cf-ray`→Cloudflare) 확인
3. 모바일 앱이 존재하는 경우, 네트워크 트래픽을 캡처(Charles Proxy, mitmproxy)하여 **모바일 전용 API**가 있는지 확인해 볼 수 있다. 모바일 API는 웹보다 보안이 느슨한 경우가 많다.

### 1.2 API 엔드포인트 수집

- 브라우저 콘솔에서 실제 호출되는 API 목록을 확인할 수 있다:
  ```javascript
  performance.getEntriesByType('resource')
    .filter(e => e.name.includes('/api/'))
    .map(e => e.name)
  ```
- Next.js 사이트라면 `__NEXT_DATA__`에 초기 데이터가 포함되어 있을 수 있다:
  ```javascript
  JSON.parse(document.getElementById('__NEXT_DATA__').textContent)
  ```

### 1.3 인증 요구사항 분석

| 확인 항목 | 방법 |
|----------|------|
| 로그인 필요 여부 | 비로그인 상태에서 API 호출 시 401/403 발생 여부 |
| 쿠키/세션 의존도 | 쿠키 삭제 후 접근 가능 여부 |
| 내부 토큰 존재 | 브라우저 콘솔에서 `fetch('/api/...')` 수동 호출 시 401이면 내부 토큰이 필요할 수 있음 |
| CSRF 보호 | hidden form 필드나 커스텀 헤더 존재 여부 |

### 1.4 JS Challenge 감지

HTTP 클라이언트로 첫 요청을 보냈을 때, 응답이 **정상 페이지보다 극도로 짧다면** JS 챌린지 페이지일 수 있다:
- 정상 페이지: 보통 100,000+ 바이트
- JS 챌린지: ~1,000~2,000 바이트 (스크립트 태그만 포함)
- 응답 HTML에 `<script>` 태그와 `location.reload(true)` 같은 패턴이 있다면 JS 챌린지일 가능성이 높다

---

## Phase 2: 보안 메커니즘 식별

사이트가 사용하는 봇 탐지 시스템과 방어 계층을 파악한다. 상세한 봇 탐지 시스템별 분석은 [references/bot-detection-systems.md](references/bot-detection-systems.md)를 참조한다.

### 2.1 봇 탐지 시스템 식별 체크리스트

| 증상 | 가능한 원인 |
|-----|-----------| 
| `Reference #18...` + `edgesuite.net` | **Akamai Bot Manager** |
| `cf-ray` 헤더, JS Challenge 페이지 | **Cloudflare** |
| `_px` 쿠키, PerimeterX 스크립트 | **PerimeterX** |
| `datadome` 쿠키 | **DataDome** |
| `418 I'm a teapot` | 서비스 자체 봇 탐지 (네이버 ncaptcha WASM 등) |
| `bvsd` hidden 필드 | 행동 분석 기반 시스템 (BVSD) |
| `_abck`, `bm_s`, `bm_sz` 쿠키 | Akamai 마커 쿠키 |

### 2.2 방어 계층 분석 (5-Layer 모델)

```
Layer 5: 행동 분석 (마우스, 스크롤, 키 입력 패턴)
Layer 4: JavaScript 검증 (navigator.webdriver, Canvas, WebGL)
Layer 3: 쿠키/세션 검증 (봇 마커 쿠키, 챌린지 토큰)
Layer 2: HTTP 헤더 분석 (헤더 순서, Sec-* 헤더)
Layer 1: TLS Fingerprint (JA3 해시, ALPN, 암호화 스위트)
```

간단한 `requests.get()` 테스트 결과로 어느 계층에서 차단되는지 가늠해 볼 수 있다:
- **403 즉시** → Layer 1~2 (TLS/헤더 문제)일 가능성
- **401** → Layer 3 (세션/인증 필요)일 가능성
- **200이지만 빈 페이지(응답 크기 극소)** → Layer 4 (JS 실행 필요)일 가능성
- **418** → 자체 봇 탐지

### 2.3 브라우저 환경 탐지에 대한 핵심 인사이트

> 자동화 도구(Selenium 등)가 실행한 브라우저는 **사람이 직접 조작해도** 봇으로 판정될 수 있다.

이는 일부 봇 탐지 시스템이 사용자의 **행동**이 아니라 **브라우저 환경 자체**(navigator.webdriver, CDP 흔적, 자동화 플래그 등)를 탐지하기 때문이다. 따라서 단순히 "인간처럼 동작"하는 것만으로는 부족하고, 브라우저 환경의 자동화 흔적을 제거하는 것이 우선이다.

---

## Phase 3: 크롤링 전략 결정

아래 의사결정 트리를 참고하여 최적의 크롤링 방법을 탐색한다. 각 기법의 상세 구현은 [references/crawling-techniques.md](references/crawling-techniques.md)를 참조한다.

```
시작
  │
  ▼
모바일 전용 API가 존재하는가?
  │
  ├── YES → 모바일 API에 세션 없이 접근해 볼 수 있는가?
  │          ├── YES → ★ Level 1: 모바일 API 직접 호출 시도 (가장 효율적일 수 있음)
  │          └── NO  → 앱 헤더 위장으로 인증을 시도해 볼 수 있음
  │                     ├── 성공 → Level 1: 앱 헤더 위장 + curl_cffi
  │                     └── 실패 → Level 2로 이동
  │
  └── NO → 단순 HTTP 요청(requests/curl_cffi)으로 데이터 접근을 시도해 볼 수 있음
            │
            ├── 성공 → ★ Level 1: HTTP 직접 요청
            │
            └── 실패 (418/403) → Next.js 사이트인가? (__NEXT_DATA__ 존재 여부 확인)
                        │
                        ├── YES → ★ _next/data 라우트 + 브라우저 내 fetch 시도
                        │          (SSR 1페이지 + _next/data 2페이지+, 실전 검증: 0.5초/페이지)
                        │
                        └── NO → ★ Level 1.5: DrissionPage (CDP 직접) 시도
                                    │
                                    ├── 성공 → DrissionPage로 크롤링 (stealth 불필요, 빠름)
                                    │
                                    └── 실패 → Playwright+stealth / UC 시도
                                                │
                                                ├── 성공 → Level 2: 하이브리드 또는 Level 3: 네트워크 캡처
                                                │
                                                └── 실패 → Level 3: 브라우저 네트워크 캡처를 고려
```

### 전략별 요약

| 전략 | 속도 | 복잡도 | 성공 가능성 | 적합한 상황 |
|-----|------|-------|-----------|-----------|
| Level 1: HTTP 직접 호출 | ★★★ | 낮음 | 상황에 따라 다름 | 보안이 약한 API, 모바일 API |
| Level 1.5: DrissionPage (CDP 직접) | ★★★ | 낮음 | 높음 | Akamai 등 강한 봇 탐지 사이트. stealth 불필요 |
| _next/data 라우트 (브라우저 내) | ★★★ | 중간 | 매우 높음 | Next.js 사이트에서 API가 토큰으로 보호된 경우 |
| Level 2: 하이브리드 (브라우저 + HTTP) | ★★☆ | 중간 | 높을 수 있음 | 세션만 필요한 사이트 |
| Level 3: 네트워크 캡처 | ★☆☆ | 높음 | 매우 높을 수 있음 | 강한 보안이 적용된 사이트 |

### 전략이 실패했을 때 시도해 볼 수 있는 대안

| 상황 | 시도해 볼 방향 |
|-----|-------------|
| 검색 API가 강한 인증을 요구 | 카테고리/목록 API에 `KEYWORD` 필터를 추가하여 우회해 볼 수 있음 |
| 특정 API 엔드포인트가 차단됨 | 같은 데이터를 반환하는 다른 API가 있을 수 있음 (예: 웹 API vs 모바일 API) |
| API가 WASM 토큰으로 보호됨 (418) | Next.js 사이트라면 `_next/data` 라우트를 브라우저 내 fetch로 호출. 토큰 불필요 |
| 브라우저 내 JS fetch도 차단됨 | 물리적 스크롤로 자연스럽게 API 호출을 유발하고 네트워크 캡처를 시도해 볼 수 있음 |
| 모든 자동화 접근이 실패 | 1회 수동 로그인 후 세션 쿠키를 저장하여 HTTP 크롤링에 재사용해 볼 수 있음 |
| Playwright+stealth, UC 모두 차단됨 | **DrissionPage**(CDP 직접)를 시도. WebDriver 프로토콜 자체가 탐지 원인일 수 있음 |

---

## Phase 4: 구현 가이드

선택한 전략에 따라 구현한다. 상세 코드 패턴과 예제는 [references/crawling-techniques.md](references/crawling-techniques.md)를 참조한다.

### 4.1 Level 1: HTTP 직접 요청

1. `requests`로 시작해 볼 수 있다. 실패하면 `curl_cffi`로 TLS 지문 위장을 시도해 볼 수 있다.
2. TLS 지문과 User-Agent의 일관성을 유지하는 것이 중요하다. iOS 앱으로 위장한다면 `safari15_5`, Android라면 `chrome120_android`가 적절할 수 있다.
3. 모바일 API 사용 시 앱 전용 헤더(앱 버전, 플랫폼 정보 등)가 필요할 수 있다.

### 4.2 Level 2: 하이브리드 방식

1. 브라우저(undetected-chromedriver 또는 Playwright + stealth)로 1회 세션을 생성해 볼 수 있다.
2. 유효한 쿠키를 추출하여 HTTP 클라이언트에 주입한다.
3. 세션 만료 시 자동 재생성 로직을 고려할 수 있다.

### 4.3 Level 3: 네트워크 캡처

1. Playwright/Selenium으로 브라우저를 열고 `page.on("response")` 이벤트 리스너를 등록한다.
2. 페이지를 방문하면 브라우저가 내부적으로 호출하는 모든 API 응답이 자동으로 캡처된다.
3. 무한 스크롤 사이트에서는 물리적 스크롤을 수행하며 추가 데이터를 캡처해 볼 수 있다.
4. 대안으로 Fetch Monkey Patching(`window.fetch`를 래퍼로 교체)을 시도해 볼 수 있다.

### 4.4 DrissionPage (CDP 직접 접근)

Playwright+stealth, undetected-chromedriver가 모두 차단될 때의 대안이다. WebDriver 프로토콜 대신 **Chrome DevTools Protocol(CDP)을 직접 사용**하여 브라우저를 제어하므로, WebDriver 기반 도구들이 남기는 자동화 흔적이 근본적으로 존재하지 않는다.

1. `pip install DrissionPage`로 설치한다.
2. stealth 플러그인이나 별도의 패치 없이도 Akamai 등 강한 봇 탐지를 통과한 실전 사례가 있다.
3. SSR 페이지의 DOM 파싱과 결합하면 Level 1 수준의 단순함으로 강한 보안 사이트를 크롤링할 수 있다.

상세 코드 패턴은 [references/crawling-techniques.md](references/crawling-techniques.md)를 참조한다.

### 4.5 로그인이 필요한 경우

로그인 자동화 상세 전략은 [references/anti-detection-strategies.md](references/anti-detection-strategies.md)를 참조한다.

1. **Playwright + playwright-stealth** 조합이 가장 안정적인 경향이 있다.
2. `page.fill()` 같은 단순 입력이 가장 자연스러울 수 있다. 과도한 인간 시뮬레이션은 오히려 의심을 유발할 수 있다.
3. 헤드리스 모드에서 입력이 실패하면 **CDP `Input.insertText`**를 시도해 볼 수 있다.
4. 로그인 성공 후 쿠키를 파일로 저장하고, 이후 HTTP 요청에 재사용하는 것을 고려할 수 있다.

---

## Phase 5: 데이터 추출

캡처된 데이터에서 원하는 정보를 추출한다. 상세 패턴은 [references/data-extraction-patterns.md](references/data-extraction-patterns.md)를 참조한다.

### 5.1 추출 전략 우선순위

1. **API JSON 응답** → 가장 깔끔하고 완전한 데이터일 가능성이 높음
2. **전역 JavaScript 변수** (`__NEXT_DATA__`, `__next_f`) → SSR 초기 데이터가 있을 수 있음
3. **DOM 파싱** → 최후의 수단 (클래스명 변경에 취약)

### 5.2 JSON 응답이 복잡한 경우

재귀적 탐색으로 원하는 패턴을 찾아볼 수 있다:
```python
def extract_recursive(data, target_key):
    found = []
    if isinstance(data, dict):
        if target_key in data:
            found.append(data[target_key])
        for value in data.values():
            found.extend(extract_recursive(value, target_key))
    elif isinstance(data, list):
        for item in data:
            found.extend(extract_recursive(item, target_key))
    return found
```

---

## Phase 6: 트러블슈팅

### 6.1 에러 코드별 시도해 볼 방향

| 에러 | 가능한 원인 | 시도해 볼 방향 |
|-----|-----------|-------------|
| **403 Forbidden** | TLS 지문 불일치 또는 봇 탐지 | curl_cffi로 TLS 위장, 또는 브라우저 사용으로 전환을 고려 |
| **401 Unauthorized** | 세션/토큰 없음 또는 내부 인증 실패 | 브라우저 세션 생성 후 쿠키 주입, 또는 네트워크 캡처로 전환을 고려 |
| **418 I'm a teapot** | 서비스 자체 봇 탐지 (ncaptcha WASM 토큰 등) | Next.js라면 `_next/data` 라우트 시도, 아니면 브라우저 내부 fetch 또는 Level 3 전환 고려 |
| **429 Too Many Requests** | Rate Limit 초과 | 요청 간 랜덤 딜레이 추가, 프록시 로테이션 고려 |
| **200 + 응답 크기 극소** | JavaScript 미실행 (JS Challenge) | 브라우저 자동화가 필요할 수 있음 (Level 2 이상) |
| **CAPTCHA 발생** | 봇 의심 플래그 | 수동 해결 후 세션 저장, 또는 캡차 해결 서비스 연동 고려 |

### 6.2 Playwright+stealth, UC 모두 차단될 때

Playwright+stealth, undetected-chromedriver가 모두 차단되는 경우, **WebDriver 프로토콜 자체가 탐지 원인**일 수 있다.

**진단 방법**: Akamai의 `_abck` 쿠키 값을 확인한다.
- `~-1~` 포함 → 봇으로 판정됨 (센서가 자동화 환경을 감지)
- `~0~` 포함 → 정상 통과

**해결**: DrissionPage를 사용한다. CDP를 직접 사용하므로 WebDriver 프로토콜의 흔적이 없다. 실전에서 Playwright+stealth와 UC가 모두 실패한 Akamai 사이트에서 DrissionPage로 즉시 성공한 사례가 있다.

### 6.3 기존에 작동하던 크롤러가 갑자기 차단되었을 때

체계적 진단 절차를 시도해 볼 수 있다:

1. **HAR 파일로 성공 요청 분석 (가장 먼저)**: Chrome DevTools에서 수동으로 동일 작업을 수행하고 "Save all as HAR"로 저장. 성공 요청에 포함된 커스텀 헤더, 토큰, 쿠키를 크롤러의 요청과 비교하면 차단 원인을 빠르게 파악할 수 있다.
2. **상세 로깅 추가**: 요청 URL, 헤더, 응답 코드, 응답 크기를 기록하여 정확한 실패 지점을 파악
3. **보안 정책 변경 확인**: 서비스의 보안 정책이 업데이트되었을 수 있음 (ncaptcha WASM 토큰 도입, 연말/연초 보안 강화 등)
4. **설정 검토**: TLS `impersonate` 값과 User-Agent가 일치하는지 확인. 단, 버전 불일치가 진짜 원인인지 성급하게 결론짓지 말 것 — 실전에서 3중 버전 불일치를 모두 수정해도 차단이 풀리지 않았던 사례가 있음 (진짜 원인은 새로운 토큰 보호 도입이었음)
5. **라이브러리 업데이트**: undetected-chromedriver, playwright-stealth 등 우회 도구의 최신 버전이 있는지 확인

### 6.4 TLS 지문 불일치 진단

위장 대상과 TLS impersonate 값이 일치하는지 확인한다:

| 위장 대상 | impersonate 값 | User-Agent 예시 |
|---------|---------------|----------------|
| iOS 앱 | `safari15_5` | `(iPhone; iOS 17.x...)` |
| Android 앱 | `chrome120_android` | `(Linux; Android 14...)` |
| PC Chrome | `chrome120` | `(Windows NT 10.0; Win64...)` |
| Mac Safari | `safari15_5` | `(Macintosh; Intel Mac OS X...)` |

### 6.5 시도하지 않는 것이 좋을 수 있는 것들 (실패 사례에서 얻은 교훈)

| 시도 | 왜 효과가 없었는가 |
|-----|-----------------|
| 과도한 인간 시뮬레이션 (Bezier 곡선, 타이핑 랜덤화) | 통계적으로 비정상적인 패턴이 되어 오히려 봇으로 판정될 수 있음 |
| 구형 User-Agent (IE8, Nokia 등) 사용 | 서버 측에서 UA와 무관하게 동일한 보안 정책을 적용하는 경우가 많음 |
| OS 레벨 입력 (PyAutoGUI 등) | 브라우저 환경 자체의 자동화 흔적이 남아있으면 의미가 없을 수 있음 |
| Node.js/JSDOM에서 보안 스크립트 실행 | 핵심 보안 데이터(session_keys, BVSD 등)가 실제 브라우저 환경에서만 생성될 수 있음 |
| HTTP 클라이언트로 보안 데이터 위조 | 서버 측에서 fingerprint, 타이밍, 세션 연속성 등을 검증하여 위조를 감지할 수 있음 |
| 봇 탐지 쿠키 값 변조 | 단 몇 자만 바꿔도 서버에서 즉시 무효화될 수 있음 (철저한 서버 사이드 검증) |
| `window.fetch` Monkey Patching으로 Next.js 내부 요청 캡처 | Next.js가 캐시된 fetch 참조 또는 내부 라우터를 사용하여 오버라이드를 우회할 수 있음. 직접 `_next/data` 라우트를 호출하는 것이 더 확실함 |

---

## Phase 7: 장기 유지보수

### 7.1 크롤러 유지보수 체크리스트

| 항목 | 빈도 | 설명 |
|-----|------|------|
| 우회 라이브러리 업데이트 | 월 1회 | undetected-chromedriver, playwright-stealth 등 |
| TLS/헤더 일관성 점검 | 차단 발생 시 | impersonate와 User-Agent 매칭 확인 |
| API 엔드포인트 변경 확인 | 차단 발생 시 | API 경로, 필수 파라미터 변경 여부 |
| 토큰/인증 만료 대응 | 상시 | AccessToken/JWT 만료 시간 확인, 갱신 로직 |
| 보안 정책 변화 모니터링 | 분기별 | 암호화 방식 변경(RSA→ECC 등), 새 봇 탐지 도입 |

### 7.2 토큰 라이프사이클 관리

인증 토큰이 필요한 API의 경우:
- JWT 토큰이라면 디코딩하여 `exp`(만료 시간) 필드를 확인해 볼 수 있다
- 만료 전 자동 갱신 로직을 구현하거나, 만료 시 수동으로 재발급하는 전략을 고려할 수 있다
- 일부 API는 AccessToken이 필수처럼 보여도 실제로는 더미 값으로 통과할 수 있으므로, 각 인증 필드의 실제 필수 여부를 테스트해 볼 가치가 있다

### 7.3 보안 방식 변경 대응

서비스의 보안 메커니즘은 예고 없이 변경될 수 있다:
- 암호화 알고리즘 전환 (예: RSA→ECC)으로 기존 로그인 코드가 전면 무효화될 수 있다
- 새로운 봇 탐지 솔루션 도입으로 기존 우회 방법이 통하지 않을 수 있다
- 이런 경우 Phase 1부터 다시 정찰하여 변경된 부분을 파악하는 것이 효과적이다

---

## 핵심 원칙 요약

1. **경험 기반 직관을 먼저 믿어라.** 비슷한 사이트를 다뤄본 경험이 있다면 스킬의 절차를 따르기 전에 그 직관을 먼저 시도하라. 스킬은 직관이 막혔을 때 꺼내는 도구다.
2. **항상 가장 단순한 방법(Level 1)부터 시도하고, 실패 시에만 복잡한 방법을 시도해 본다.**
3. **위장의 일관성이 중요하다.** TLS, HTTP 헤더, User-Agent, 앱 헤더 모든 계층에서 동일한 정체성을 유지할수록 차단되지 않을 가능성이 높다.
4. **과도한 인간 시뮬레이션보다 단순한 동작이 효과적일 수 있다.** 실전에서 `page.fill()`이 Bezier 곡선 마우스 움직임보다 성공률이 높은 경우가 있었다.
5. **"행동을 흉내내기"보다 "환경의 자동화 흔적 제거"가 효과적일 수 있다.** 실제 브라우저를 사용하되 자동화 흔적만 숨기는 접근이 유효했던 사례가 많다.
6. **"요청을 모방"하기보다 "브라우저가 수행하는 것을 관찰"하는 것이 견고할 수 있다.** 네트워크 캡처는 내부 토큰 생성을 직접 구현할 필요를 없앤다.
7. **WebDriver 기반 도구가 모두 차단되면 프로토콜 자체를 의심하라.** Playwright+stealth, UC가 모두 실패하면 WebDriver 프로토콜이 탐지 원인일 수 있다. DrissionPage(CDP 직접)로 전환하면 해결되는 경우가 있다.
8. **API가 토큰으로 보호되면 "같은 데이터의 다른 경로"를 찾아라.** Next.js 사이트에서 API 엔드포인트가 ncaptcha 등으로 보호되어도, `_next/data` 라우트나 SSR `__NEXT_DATA__`로 동일한 데이터에 접근할 수 있다. 보호된 API를 직접 뚫으려 하기보다 우회 경로를 먼저 탐색하는 것이 효율적이다.
9. **진단 시 "의심스러운 설정"에 매몰되지 마라.** 버전 불일치, 헤더 차이 등 여러 의심 요소가 동시에 보이면 하나씩 고치며 시간을 낭비할 수 있다. HAR 파일로 성공 요청을 먼저 분석하여 실제로 무엇이 필요한지 파악하는 것이 더 빠르다.
10. **법적/윤리적 측면도 고려한다.** robots.txt와 이용약관을 확인하고, 과도한 요청을 삼간다.
