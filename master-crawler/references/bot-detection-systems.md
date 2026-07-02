# 봇 탐지 시스템 종합 분석

## 1. 봇 탐지의 5계층 모델

현대 봇 탐지 시스템은 단일 기법이 아닌 다중 계층 방어를 사용한다. 하위 계층부터 상위 계층까지 모두 통과해야 접근이 허용된다.

```
┌──────────────────────────────────────────────────────────┐
│ Layer 5: 행동 분석                                        │
│   마우스 움직임, 스크롤 패턴, 클릭 타이밍, 키 입력 리듬       │
├──────────────────────────────────────────────────────────┤
│ Layer 4: JavaScript 검증                                  │
│   navigator.webdriver, Canvas, WebGL fingerprint          │
├──────────────────────────────────────────────────────────┤
│ Layer 3: 쿠키/세션 검증                                    │
│   봇 마커 쿠키, 챌린지 토큰, CSRF 토큰                      │
├──────────────────────────────────────────────────────────┤
│ Layer 2: HTTP 헤더 분석                                    │
│   헤더 순서, Accept-* 값, Sec-Fetch-* 헤더                 │
├──────────────────────────────────────────────────────────┤
│ Layer 1: TLS Fingerprint                                  │
│   JA3/JA3S 해시, ALPN, 암호화 스위트 목록·순서              │
└──────────────────────────────────────────────────────────┘
```

### 각 크롤링 방법의 계층 통과 현황 (실전 검증 결과)

| 방법 | L1 TLS | L2 HTTP | L3 쿠키 | L4 JS | L5 행동 | 결과 |
|-----|--------|---------|--------|-------|--------|------|
| requests (Python) | ❌ | ✅ | ❌ | ❌ | ❌ | 실패 |
| curl_cffi (TLS 위장) | ✅ | ✅ | ⚠️ | ❌ | ❌ | 부분 성공 |
| 모바일 API + 앱 헤더 | ✅ | ✅ | N/A | N/A | N/A | **성공** |
| 일반 Selenium | ✅ | ✅ | ✅ | ❌ | ✅ | 실패 |
| Selenium + 수동 조작 | ✅ | ✅ | ✅ | ❌ | ✅ | **실패** |
| undetected-chromedriver | ✅ | ✅ | ✅ | ✅ | ✅ | **사이트에 따라 다름** ⚠️ |
| Playwright + stealth | ✅ | ✅ | ✅ | ✅ | ✅ | **사이트에 따라 다름** ⚠️ |
| **DrissionPage (CDP 직접)** | ✅ | ✅ | ✅ | ✅ | ✅ | **성공** |

> **주목할 점 1**: Selenium으로 열린 브라우저를 사람이 직접 조작해도 차단된 사례가 있다. 이는 Layer 4(브라우저 환경 자체)에서 자동화 도구의 흔적이 남아있기 때문이다.

> **주목할 점 2**: undetected-chromedriver와 Playwright+stealth는 많은 사이트에서 성공하지만, **Akamai Bot Manager가 강하게 적용된 사이트에서는 실패할 수 있다.** 이 도구들은 WebDriver 프로토콜의 표면적인 흔적(navigator.webdriver 등)은 숨기지만, WebDriver 프로토콜 자체의 내부 통신 패턴까지는 숨기지 못할 수 있다. 실전에서 두 도구 모두 Akamai에 차단된 후 DrissionPage(CDP 직접)로 즉시 성공한 사례가 확인되었다.

---

## 2. 주요 봇 탐지 서비스별 특성

### 2.1 Akamai Bot Manager

**식별 방법**:
- 차단 시 `Reference #18.xxxx.xxxxx.xxxxx` 형식의 참조 코드 표시
- 에러 URL에 `edgesuite.net` 도메인 포함
- `_abck`, `bm_s`, `bm_sz`, `bm_mi`, `ak_bmsc` 등의 마커 쿠키 존재

**핵심 메커니즘 - `bm_s` 쿠키**:
- Akamai의 JavaScript 센서가 브라우저 환경(Canvas, WebGL, 폰트 등)을 분석하여 생성
- **서버에서 철저히 검증됨**: 단 5자만 변경해도 즉시 차단된 사례가 있음 (403 Forbidden)
- HTTP 클라이언트로도 `bm_s`를 수신할 수는 있지만, JS 센서 데이터가 없어 **무효**일 수 있음
- 유효한 `bm_s`는 실제 브라우저의 JavaScript가 생성해야 할 가능성이 높음
- 12개 세션 쿠키 중 `bm_s` 하나만으로 접근에 성공한 사례가 있음

**`_abck` 쿠키 값으로 탐지 결과 판별**:
- `_abck` 값에 `~-1~` 포함 → 봇으로 판정됨 (센서가 자동화 환경을 감지)
- `_abck` 값에 `~0~` 포함 → 정상 통과 (인간으로 판정)
- 실전에서 Playwright+stealth로 `_abck`에 `~-1~`이 지속적으로 나타나면, 해당 도구로는 우회가 불가능하다는 강한 신호이다.

**시도해 볼 수 있는 우회 전략 (우선순위 순)**:
1. **DrissionPage (CDP 직접)**: WebDriver 프로토콜을 사용하지 않으므로 자동화 흔적이 근본적으로 없다. Playwright+stealth와 UC가 모두 실패한 사이트에서 즉시 성공한 실전 사례가 있다. stealth 패치도 불필요하다.
2. `undetected-chromedriver` 또는 Playwright + stealth로 브라우저 세션을 생성하여 유효한 쿠키를 획득
3. 생성된 쿠키를 HTTP 클라이언트에 주입하여 하이브리드 크롤링을 시도

**JS Challenge 페이지 감지**:
- 세션 없이 접근 시 정상 페이지(100,000+ 바이트) 대신 극도로 짧은 응답(~1,220 바이트)이 올 수 있음
- 이 응답에는 `<script>` 태그와 `location.reload(true)` 패턴이 포함된 JS 챌린지 페이지임
- 응답 크기를 비교하면 JS 챌린지 여부를 빠르게 판별할 수 있음

### 2.2 Cloudflare

**식별 방법**:
- 응답 헤더에 `cf-ray` 존재
- JavaScript Challenge 페이지 표시
- `__cf_bm`, `cf_clearance` 쿠키

**특성**:
- JS Challenge 기반 + 환경 기반 복합 탐지
- TLS Fingerprint 활용
- undetected-chromedriver로 우회할 수 있었던 사례가 있음

### 2.3 자체 봇 탐지 시스템 (네이버 등)

**식별 방법**:
- `418 I'm a teapot` 응답 코드 (네이버)
- CAPTCHA 발생 (nCaptcha)
- `bvsd` hidden 필드 존재

#### ncaptcha WASM 토큰 보호 (2025년~ 확인)

네이버 쇼핑 검색 API(`/api/search/all`) 등 일부 엔드포인트에 적용된 새로운 보호 메커니즘. 기존에 쿠키만으로 접근 가능하던 API가 갑자기 418을 반환하기 시작했다면 이 패턴을 의심할 수 있다.

**동작 흐름**:
```
1. 브라우저가 ncaptcha WASM 모듈 로드
2. WASM이 브라우저 환경 분석 → cipherText 생성 (5000+ chars)
3. POST ncpt.naver.com/v2/tokens {cipherText, siteKey} → tokenId 수신
4. 이후 API 요청에 x-wtm-ncaptcha-token 헤더 포함 → 200 OK
```

**핵심 특성**:
- cipherText는 **WASM 바이너리가 브라우저 환경을 분석하여 생성**하므로 외부에서 위조가 극히 어려움
- curl_cffi, urllib, 시스템 curl 등 **모든 외부 HTTP 클라이언트**가 418로 차단됨
- TLS 지문, 헤더 버전, 쿠키를 완벽하게 맞춰도 ncaptcha 토큰 없이는 차단
- 토큰이 없는 요청은 응답 본문 없이 HTTP 418만 반환

**진단 방법**: HAR 파일(Chrome DevTools → Network → Save all as HAR)을 분석하여 `ncpt.naver.com` 호출과 `x-wtm-ncaptcha-token` 헤더 존재 여부를 확인

**시도해 볼 수 있는 우회 전략**:
1. **`_next/data` 라우트 활용** (Next.js 사이트인 경우): 브라우저 세션 내에서 `/_next/data/{buildId}/...` 경로로 fetch하면 ncaptcha 토큰 없이 동일 데이터를 얻을 수 있음 (실전 검증 완료)
2. **SSR `__NEXT_DATA__` 추출**: 첫 페이지는 HTML 내 `<script id="__NEXT_DATA__">` 에서 직접 추출
3. **브라우저 내부 fetch**: `driver.execute_script(fetch(...))` 로 same-origin 요청을 수행하면 브라우저의 모든 세션 상태가 자동 포함됨

**BVSD (Behavioral Verification Security Data)** 상세 구조:
```json
{
  "uuid": "고유ID-시퀀스",
  "encData": "LZString 압축된 stateFootprint"
}

// stateFootprint 내부:
{
  "a": "uuid",
  "b": "라이브러리 버전",
  "c": "터치 지원 여부",
  "d": [/* 키보드 입력 로그 */],
  "e": {/* 기기 방향 센서 */},
  "f": {/* 기기 모션 센서 */},
  "g": {/* 마우스 이동 로그 */},
  "h": "fingerprint 해시",
  "i": {/* 브라우저 fingerprint 상세 */},
  "j": "처리 소요 시간(ms)"
}
```

- BVSD는 브라우저의 실제 JavaScript 런타임에서만 생성 가능한 것으로 보임
- HTTP 클라이언트로 BVSD를 위조하더라도 서버 검증에서 실패한 사례가 있음 (fingerprint, 타이밍, 세션 연속성 등을 검증)
- **시도해 볼 수 있는 접근**: Playwright + stealth로 실제 브라우저에서 BVSD를 자연스럽게 생성시키기

### 2.4 기타 서비스 비교표

| 서비스 | 주요 탐지 방식 | 시도해 볼 수 있는 우회 방향 |
|--------|-------------|----------------------|
| **Akamai** | 환경 + 행동 + WebDriver 프로토콜 탐지 | **DrissionPage (CDP 직접)** 또는 실제 브라우저 |
| **Cloudflare** | JS Challenge + TLS | curl_cffi 또는 브라우저 |
| **PerimeterX** | 마우스 움직임 분석 | Playwright + stealth |
| **DataDome** | 고급 행동 분석 | 실제 브라우저가 필요할 수 있음 |
| **reCAPTCHA v3** | 점수 기반 | 자연스러운 탐색 패턴 시도 |
| **네이버 (자체)** | BVSD + ECC 암호화 + ncaptcha WASM | Playwright + stealth, 또는 _next/data 라우트 우회 |

---

## 3. TLS Fingerprint (JA3) 상세

### 3.1 JA3 해시란?

TLS 핸드셰이크 과정에서 클라이언트가 전송하는 정보의 패턴을 MD5 해시한 값이다:

구성 요소:
- TLS 버전
- 지원 암호화 스위트 목록 및 순서
- 지원 확장 기능 목록 및 순서
- 지원 타원 곡선 그룹
- 지원 EC 포인트 포맷

### 3.2 브라우저별 TLS 지문 차이

| 클라이언트 | 특징 |
|-----------|------|
| Chrome (Windows) | Windows 특화 암호화 스위트, GREASE 확장 |
| Safari (iOS) | Apple 특화 암호화 스위트, 다른 확장 순서 |
| Firefox | Mozilla 고유 패턴 |
| Python requests | 매우 단순한 패턴 → 봇으로 즉시 식별될 수 있음 |
| curl (기본) | 매우 단순 → 즉시 식별될 수 있음 |
| curl_cffi | 지정한 브라우저와 동일한 JA3 해시 생성 |

### 3.3 TLS-User-Agent 일관성 원칙

**핵심: "위장의 일관성이 중요하다"**

모든 계층에서 동일한 정체성을 유지하는 것이 차단을 피하는 데 도움이 될 수 있다:
- Layer 1 (TLS): 위장 대상의 TLS 지문
- Layer 2 (HTTP): 위장 대상의 User-Agent
- Layer 3 (App): 위장 대상의 앱 헤더

불일치가 차단으로 이어진 실제 사례:
- User-Agent: "나는 iPhone 앱이다" + TLS `impersonate`: `chrome120` (PC Chrome) → **즉시 차단됨**
- 해결: impersonate를 `safari15_5` (iOS의 기본 브라우저 엔진)로 변경하여 성공

| 위장 대상 | impersonate | User-Agent 패턴 |
|---------|------------|----------------|
| iOS 앱 | `safari15_5` | `(iPhone; iOS 17.x...)` |
| Android 앱 | `chrome120_android` | `(Linux; Android 14...)` |
| PC Chrome | `chrome120` | `(Windows NT 10.0; Win64...)` |
| Mac Safari | `safari15_5` | `(Macintosh; Intel Mac OS X...)` |

**추가 주의**: User-Agent에 포함된 OS/앱 버전이 실제로 존재하는 현실적인 값이어야 한다. 존재하지 않는 버전(예: iOS 26.1)을 사용하면 의심을 유발할 수 있다.

---

## 4. 쿠키/세션 검증 메커니즘

### 4.1 Akamai 쿠키 체계

| 쿠키 | 역할 | 중요도 |
|------|------|-------|
| `_abck` | Akamai 봇 관리 메인 쿠키 | 높음 |
| `bm_s` | 세션 검증 (JS 센서 결과 포함) | **최고** |
| `bm_sz` | 세션 크기 관련 | 중간 |
| `bm_mi` | 모바일 식별 | 중간 |
| `ak_bmsc` | 봇 관리 세션 쿠키 | 중간 |

### 4.2 실험으로 검증된 사실

- 12개 세션 쿠키 중 **`bm_s` 하나만으로** 웹 접근에 성공한 사례가 있음
- `bm_s` 값을 단 5자만 변경해도 **즉시 실패**한 사례가 있음 (397바이트 에러 응답)
- HTTP 클라이언트로 받은 `bm_s`는 JS 센서 데이터가 없어 **무효**일 수 있음
- 시사점: 봇 감지 쿠키는 단순 형식 검사가 아니라 서버에서 내용을 검증할 가능성이 높음

### 4.3 쿠키 생성 과정 비교

```
[브라우저 경우 - 유효한 쿠키 생성 가능]
1. 브라우저가 페이지 로드
2. 봇 탐지 JS 센서 실행
3. 브라우저 환경 분석 (Canvas, WebGL, fonts 등)
4. 센서 데이터로 쿠키 생성 ← 유효한 값

[HTTP 클라이언트 경우 - 무효한 쿠키]
1. HTTP 클라이언트가 페이지 요청
2. JavaScript 실행 불가
3. 서버가 기본 쿠키 반환 ← 센서 데이터 없음
4. 이 쿠키로 다음 요청 시 거부될 수 있음
```

---

## 5. 보안 메커니즘 변화에 대한 인사이트

웹 서비스의 보안 메커니즘은 예고 없이 변경될 수 있다:

| 변화 유형 | 실제 사례 | 영향 |
|---------|---------|------|
| 암호화 알고리즘 변경 | RSA → ECC (P-256) 전환 | 기존 로그인 코드가 전면 무효화될 수 있음 |
| TLS 검증 정책 강화 | 연말/연초 보안 정책 업데이트 | 기존 작동하던 크롤러가 갑자기 차단될 수 있음 |
| 봇 탐지 모델 개선 | ML 기반 탐지 모델 학습 | 새로운 불일치 패턴이 감지될 수 있음 |
| API 필수 필드 변경 | 새 인증 헤더가 요구됨 | 기존 API 호출이 실패할 수 있음 |
| 보안 데이터 JS 의존성 | session_keys가 HTML에서 JS 동적 생성으로 변경 | HTTP-only 접근이 불가능해질 수 있음 |

**시도해 볼 수 있는 대응**:
- 크롤러에 상세 로깅을 구현하여 문제 발생 시 정확한 실패 지점을 파악
- 차단 발생 시 Phase 1(정찰)부터 다시 시작하여 변경된 부분을 파악
- 우회 라이브러리의 최신 버전과 커뮤니티 이슈를 확인
