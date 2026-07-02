# 탐지 회피 전략 상세 레퍼런스

## 1. TLS 지문 위장

### 1.1 curl_cffi 사용법

```python
from curl_cffi import requests as curl_requests

# 기본 사용
session = curl_requests.Session(impersonate="chrome120")
response = session.get("https://target-site.com/api/data")

# 쿠키와 함께 사용
response = curl_requests.get(
    url,
    cookies={"session_id": "abc123"},
    impersonate="chrome120"
)
```

### 1.2 impersonate 매칭 가이드

| 위장 대상 | impersonate | User-Agent 필수 패턴 |
|---------|------------|-------------------|
| iOS 앱 | `safari15_5` | `(iPhone; iOS 17.x; Scale/3.00)` |
| Android 앱 | `chrome120_android` | `(Linux; Android 14; Pixel...)` |
| PC Chrome (Windows) | `chrome120` | `(Windows NT 10.0; Win64; x64)` |
| PC Safari (macOS) | `safari15_5` | `(Macintosh; Intel Mac OS X 10_15)` |
| Firefox | `firefox120` | `(Windows NT 10.0; Win64; x64; rv:120.0) Gecko/...` |

### 1.3 일관성 검증 체크리스트

403 에러 발생 시 다음 항목들을 점검해 볼 수 있다:

- [ ] `impersonate` 값이 User-Agent의 브라우저/OS와 일치하는가?
- [ ] User-Agent의 OS/앱 버전이 실제로 존재하는 현실적인 값인가?
- [ ] 앱 위장 시 앱 전용 헤더가 모두 포함되었는가?
- [ ] 헤더 순서가 실제 브라우저와 유사한가?
- [ ] 이전에 작동했던 설정이 변경된 부분은 없는가?

### 1.4 버전 불일치 진단의 함정 (실전 교훈)

기존 크롤러가 갑자기 차단되었을 때, **버전 불일치가 원인이라는 가설에 과도하게 집중하면 진짜 원인을 놓칠 수 있다.**

실전 사례: Chrome이 131 → 146으로 자동 업데이트된 후 크롤러가 차단됨. 3중 버전 불일치 발견:
| 계층 | 버전 |
|------|------|
| 쿠키 (Selenium 로그인) | Chrome 146 (실제 설치) |
| HTTP 헤더 (sec-ch-ua) | Chrome 131 (하드코딩) |
| TLS 핑거프린트 (curl_cffi) | chrome124 (하드코딩) |

**결과**: 버전을 모두 일치시켜도(Chrome 146 헤더 + chrome142 TLS) 여전히 418로 차단됨. **진짜 원인은 ncaptcha WASM 토큰 보호 도입**이었음. 버전 불일치와 동시에 발생한 것은 우연의 일치.

**교훈**: 여러 "의심스러운" 설정을 발견하면, 하나씩 수정하며 테스트하기보다 **먼저 HAR 파일로 실제 브라우저의 성공 요청을 분석**하여 어떤 추가 헤더/토큰이 필요한지 확인하는 것이 더 빠르다.

### 1.5 HAR 파일을 활용한 요청 분석

Chrome DevTools → Network → "Save all as HAR with content" 로 저장한 HAR 파일은 성공한 요청의 전체 정보를 담고 있어, 차단 원인 분석에 매우 유용하다.

**HAR 파일에서 확인할 핵심 항목**:
- 요청 헤더 중 **커스텀 인증 헤더** (예: `x-wtm-ncaptcha-token`)
- 요청 전에 발생한 **토큰 생성 요청** (예: `ncpt.naver.com/v2/tokens`)
- 토큰 생성에 필요한 **요청 본문** (예: `cipherText`, `siteKey`)
- 응답 상태 코드와 본문 크기로 **성공/실패 패턴 구분**

```python
# HAR 파일 분석 스크립트 예시
import json
with open('network.har', 'r', encoding='utf-8') as f:
    har = json.load(f)

for entry in har['log']['entries']:
    url = entry['request']['url']
    status = entry['response']['status']
    headers = {h['name']: h['value'] for h in entry['request']['headers']}
    print(f"[{status}] {url[:80]}")
    # 커스텀 헤더 확인
    for name, value in headers.items():
        if name.startswith('x-') or name == 'authorization':
            print(f"  {name}: {value[:50]}...")
```

---

## 2. 브라우저 자동화 흔적 제거

### 2.1 주요 탐지 포인트 및 대응

| 탐지 대상 | 탐지 방법 | 시도해 볼 수 있는 우회 |
|---------|---------|-----------------|
| `navigator.webdriver` | `true`이면 자동화 도구 | stealth가 `undefined`로 변경 |
| `cdc_` 문자열 | ChromeDriver 고유 식별자 | undetected-chromedriver가 제거 |
| `$cdc_` 전역 변수 | 자동화 탐지용 변수 | undetected-chromedriver가 제거 |
| `enable-automation` 스위치 | Chrome 자동화 플래그 | 비활성화 |
| Chrome DevTools Protocol | CDP 명령 흔적 | stealth/UC가 수정 |
| Canvas/WebGL fingerprint | 브라우저 고유 지문 | stealth가 일관된 값 반환 |
| `navigator.plugins` | 빈 배열이면 의심 | stealth가 플러그인 목록 주입 |
| `navigator.languages` | 비정상 값이면 의심 | stealth가 정상 값 설정 |

### 2.2 도구별 비교

| 도구 | 기반 | Stealth | 안정성 | 장점 |
|-----|------|---------|-------|------|
| undetected-chromedriver | Selenium/WebDriver | 내장 | 높음 | ChromeDriver 바이너리 패치 |
| Playwright + stealth | Playwright/WebDriver | 플러그인 | 매우 높음 | 비동기 지원, 다중 브라우저 |
| Puppeteer + stealth | Node.js/WebDriver | 플러그인 | 높음 | JS 생태계 최적화 |
| **DrissionPage** | **CDP 직접** | **불필요** | **매우 높음** | WebDriver 프로토콜 미사용, 자동화 흔적 근본 제거 |

### 2.3 Playwright stealth 적용

```python
from playwright.sync_api import sync_playwright
from playwright_stealth import stealth_sync

with sync_playwright() as p:
    browser = p.chromium.launch(headless=False)
    context = browser.new_context()
    page = context.new_page()

    stealth_sync(page)  # goto() 전에 호출하는 것이 좋음

    page.goto('https://target-site.com')
```

### 2.4 undetected-chromedriver 적용

```python
import undetected_chromedriver as uc

driver = uc.Chrome(use_subprocess=True)
# 자동으로 패치가 적용됨:
# - navigator.webdriver = undefined
# - navigator.plugins = [1, 2, 3, 4, 5]
# - navigator.languages = ['ko-KR', 'ko', 'en-US', 'en']
```

### 2.5 핵심 인사이트: 환경 탐지 vs 행동 탐지

> 자동화 도구가 실행한 브라우저는 사람이 직접 조작해도 봇으로 판정된 사례가 있다.

이는 봇 탐지가 사용자의 **행동**보다 브라우저 **환경 자체**(navigator.webdriver, CDP 흔적 등)를 우선적으로 검사해 볼 수 있기 때문이다. 따라서:
- 행동 시뮬레이션보다 **환경의 자동화 흔적 제거가 우선**일 수 있다
- stealth 플러그인이나 undetected-chromedriver 같은 환경 패치 도구가 효과적일 수 있다
- 일반 Selenium/Playwright를 stealth 없이 사용하면 아무리 인간처럼 행동해도 의미가 없을 수 있다

### 2.6 WebDriver 프로토콜 vs CDP 직접 접근

WebDriver 기반 도구(Selenium, Playwright, Puppeteer)가 stealth 패치를 적용해도 차단되는 경우, **프로토콜 자체가 탐지 원인**일 수 있다.

**WebDriver 프로토콜의 탐지 경로**:
```
브라우저 ←→ WebDriver 프로토콜 ←→ ChromeDriver/Playwright Server
                  ↑
          봇 탐지 시스템이 이 통신 패턴을 감지할 수 있음
```

stealth 플러그인이 숨기는 것:
- `navigator.webdriver` → `undefined`
- `cdc_` 문자열 → 제거
- `enable-automation` → 비활성화

stealth 플러그인이 숨기지 **못하는** 것:
- WebDriver 프로토콜의 내부 통신 패턴
- CDP 명령 호출 빈도 및 패턴
- 브라우저 프로세스 실행 방식의 차이

**CDP 직접 접근 (DrissionPage)의 차이**:
```
브라우저 ←→ CDP 직접 ←→ DrissionPage (Python)
                ↑
        WebDriver 레이어가 아예 없음
```

DrissionPage는 Chrome의 DevTools 프로토콜을 직접 사용한다. 이는 개발자 도구(F12)가 브라우저와 통신하는 것과 동일한 방식이다. WebDriver 프로토콜 자체가 존재하지 않으므로, WebDriver를 탐지하는 모든 기법이 무효화된다.

**실전 검증 결과**:
- Playwright + stealth + `channel="chrome"` + persistent context → Akamai 차단 (`_abck: ~-1~`)
- undetected-chromedriver → Chrome 버전 불일치 + 세션 불안정
- DrissionPage (설정 최소) → **즉시 성공** (stealth 패치 없이)

**판단 기준**: `_abck` 쿠키에 `~-1~`이 지속적으로 나타나면 WebDriver 프로토콜 탐지를 의심하고, DrissionPage로 전환을 시도한다.

---

## 3. 로그인 자동화

### 3.1 로그인 전략 탐색

```
로그인이 필요한가?
  │
  ├── 아니오 → 로그인 없이 크롤링 시도
  │
  └── 예 → HTTP로 로그인을 시도해 볼 수 있는가? (BVSD/CAPTCHA 유무 확인)
            │
            ├── 가능해 보임 → curl_cffi + TLS 위장으로 HTTP 로그인 시도
            │
            └── 어려워 보임 → 브라우저 자동화 로그인을 시도
                              │
                              ├── 헤드리스가 필요하다면 → CDP Input.insertText 고려
                              │
                              └── GUI 가능하다면 → Playwright + stealth + page.fill()
```

### 3.2 Playwright 로그인 (성공 사례)

```python
page.goto('https://target-site.com/login')

# 단순 입력이 가장 자연스러울 수 있다
page.fill('#id', user_id)
page.fill('#pw', user_pw)
page.click('#login-button')

page.wait_for_timeout(3000)

# CAPTCHA 발생 시
if 'captcha' in page.url.lower() or page.query_selector('.captcha'):
    print("CAPTCHA 발생! 수동으로 해결이 필요할 수 있습니다.")
    input("해결 후 Enter...")

# 쿠키 저장
cookies = context.cookies()
with open('session.json', 'w') as f:
    json.dump(cookies, f, indent=2)
```

### 3.3 시도하지 않는 것이 좋을 수 있는 것들 (로그인 관련 실패 사례)

| 시도 | 왜 효과가 없었는가 |
|-----|-----------------|
| Bezier 곡선 마우스 움직임 | 통계적으로 비정상적 패턴이 되어 CAPTCHA 유발 |
| 타이핑 속도 랜덤화 (50~150ms) | 너무 균일한 랜덤 분포가 의심을 유발할 수 있음 |
| 클릭 전 호버 + 스크롤 | 과도한 행동이 봇으로 판정될 수 있음 |
| **`page.fill()` 단순 입력** | **성공** — 내부적으로 적절한 이벤트 발생 |
| HTTP 직접 로그인 (모든 변형) | BVSD, session_keys 등이 JS 런타임에서만 생성될 수 있어 실패 |
| 브라우저에서 추출한 보안 데이터를 HTTP로 전송 | 서버가 세션 연속성을 검증하여 실패할 수 있음 |
| Node.js + JSDOM으로 보안 스크립트 실행 | 핵심 보안 데이터가 실제 브라우저 환경에서만 생성될 수 있음 |
| 구형 User-Agent 사용 | 서버 측에서 UA와 무관하게 동일 보안 정책 적용 |
| OS 레벨 입력 (PyAutoGUI) | 브라우저 환경 자체의 자동화 흔적이 남아 의미 없을 수 있음 |
| 평문 로그인 시도 (enctp=0) | 서버에서 암호화된 비밀번호만 수락할 수 있음 |

**핵심 패턴**: `✅ 성공: 실제 브라우저 + Stealth + 단순 입력` / `❌ 실패: HTTP 직접 요청 (어떤 조합이든)`

### 3.4 세션 재사용 패턴

```python
import requests
import json
import os
from datetime import datetime

class SessionManager:
    def __init__(self, session_file='session.json'):
        self.session_file = session_file

    def save_session(self, cookies):
        data = {
            'cookies': cookies,
            'saved_at': datetime.now().isoformat()
        }
        with open(self.session_file, 'w') as f:
            json.dump(data, f, indent=2)

    def load_session(self):
        if not os.path.exists(self.session_file):
            return None
        with open(self.session_file, 'r') as f:
            data = json.load(f)

        session = requests.Session()
        for cookie in data['cookies']:
            session.cookies.set(
                cookie['name'],
                cookie['value'],
                domain=cookie['domain']
            )
        return session

    def is_valid(self, session, check_url):
        try:
            response = session.get(check_url)
            return 'login' not in response.url.lower()
        except:
            return False
```

### 3.5 CAPTCHA 대응 전략

| 전략 | 설명 | 적합한 상황 |
|-----|------|-----------|
| 수동 해결 + 세션 저장 | 1번 수동 확인 후 쿠키 재사용 | 소규모, 가장 안정적 |
| 브라우저 프로필 유지 | 로그인 상태를 로컬 프로필에 보관 | 반복 실행이 필요한 경우 |
| CAPTCHA 해결 서비스 | 2Captcha, Anti-Captcha 등 연동 | 대규모 자동화가 필요한 경우 |
| 계정 쿨다운 | CAPTCHA 플래그 해제까지 대기 | 한 번 트리거된 경우 |

### 3.6 JavaScript 의존성이 있는 보안 시스템의 특성

일부 서비스(특히 한국 대형 포털)에서는 다음 보안 요소들이 **반드시 JavaScript 런타임에서 생성**되어야 할 수 있다:

| 보안 요소 | 설명 | HTTP로 생성 가능 여부 |
|---------|------|-------------------|
| **session_keys** | ECC 공개키와 세션 키 | ❌ HTML에 포함되지 않고 JS에서 동적 생성 |
| **BVSD encData** | 행동 데이터 압축 | ❌ 전용 JS 라이브러리가 브라우저 환경에서 생성 |
| **암호화된 비밀번호** | ECC/RSA 암호화 결과 | ❌ 클라이언트 측 JS에서 수행 |
| **fingerprint 해시** | 브라우저 고유 식별자 | ❌ Canvas, WebGL 등 브라우저 API 필요 |

이런 경우 HTTP-only 로그인은 매우 어려울 수 있으며, 실제 브라우저 사용이 필요할 가능성이 높다.

---

## 4. Rate Limiting 회피

### 4.1 기본 전략

```python
import random
import time

def random_delay(min_sec=1.5, max_sec=3.5):
    """랜덤 대기 시간"""
    time.sleep(random.uniform(min_sec, max_sec))

def human_like_scroll(driver):
    """인간처럼 자연스러운 스크롤을 시도"""
    current_position = 0
    total_height = driver.execute_script("return document.body.scrollHeight")

    while current_position < total_height:
        scroll_amount = random.randint(200, 500)
        current_position += scroll_amount
        driver.execute_script(f"""
            window.scrollTo({{
                top: {current_position},
                behavior: 'smooth'
            }});
        """)
        time.sleep(random.uniform(0.3, 0.8))
```

### 4.2 고급 전략

| 전략 | 설명 |
|-----|------|
| **프록시 로테이션** | 여러 IP를 순환하여 IP 기반 Rate Limit 회피를 시도 |
| **요청 간 딜레이** | 2~4초 랜덤 대기 (일정한 간격은 봇으로 판단될 수 있음) |
| **세션 워밍업** | 메인 페이지 방문 후 자연스럽게 카테고리로 이동하여 세션을 "워밍업" |
| **지수 백오프** | 429 수신 시 대기 시간을 지수적으로 증가 |
| **시간대 분산** | 사용자 활동이 적은 시간대에 수집 |

### 4.3 429 에러 자동 처리

```python
def request_with_retry(session, url, max_retries=3):
    for attempt in range(max_retries):
        response = session.get(url)

        if response.status_code == 200:
            return response
        elif response.status_code == 429:
            wait_time = (2 ** attempt) * random.uniform(1, 2)
            print(f"Rate limited. Waiting {wait_time:.1f}s...")
            time.sleep(wait_time)
        else:
            print(f"Error: {response.status_code}")
            break

    return None
```

---

## 5. 헤드리스 모드 주의사항

### 5.1 일반 모드 vs 헤드리스 차이

| 항목 | 일반 모드 | 헤드리스 |
|-----|---------|---------|
| 클립보드 접근 | ✅ 가능 | ❌ 제한될 수 있음 |
| ActionChains 키 입력 | ✅ 정상 | ⚠️ 불안정할 수 있음 |
| JS fetch 봇 탐지 | ✅ 통과 가능 | ❌ 418 에러가 발생할 수 있음 |
| 탐지 위험 | 낮음 | 높을 수 있음 |

### 5.2 헤드리스 모드 권장 설정

```python
# Chrome 109+ 신형 헤드리스 (발각 위험이 낮을 수 있음)
options.add_argument("--headless=new")  # 구형 --headless 보다 탐지하기 어려움
options.add_argument("--no-sandbox")
options.add_argument("--disable-blink-features=AutomationControlled")
```

### 5.3 헤드리스 모드에서의 분기 처리

일반 모드에서 되는 것이 헤드리스에서 안 될 수 있으므로 분기 처리를 고려:

```python
if headless_mode:
    # 텍스트 입력: CDP 사용을 시도
    input_text_cdp(driver, element, text)
    # API 호출: curl_cffi 사용을 시도 (브라우저 JS fetch는 418 위험)
    response = curl_requests.get(url, cookies=cookies, impersonate="chrome120")
else:
    # 텍스트 입력: 기본 fill() 사용을 시도
    page.fill('#id', text)
    # API 호출: 브라우저 내 JS fetch 사용을 시도
    result = driver.execute_script("return (async () => { ... })()")
```

---

## 6. 체계적 진단 프로세스

기존에 작동하던 크롤러가 갑자기 차단되었을 때, 시도해 볼 수 있는 체계적 진단 절차:

### 6.1 Step 1: 상세 로깅 추가

```python
import logging

logging.basicConfig(
    level=logging.DEBUG,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler("debug_crawler.log", encoding='utf-8'),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger("Crawler")

# 주요 로깅 포인트
logger.debug(f"Request URL: {url}")
logger.debug(f"Request Headers: {headers}")
logger.debug(f"Response Status: {response.status_code}")
logger.debug(f"Response Length: {len(response.text)}")
logger.debug(f"Response Cookies: {dict(response.cookies)}")
logger.error(f"HTTP Error: {response.status_code}", exc_info=True)
```

### 6.2 Step 2: 설정 검토

| 점검 항목 | 확인 방법 |
|---------|---------|
| TLS impersonate ↔ User-Agent 일치 | impersonate가 UA의 브라우저/OS와 맞는지 확인 |
| OS/앱 버전 현실성 | 존재하지 않는 버전(예: iOS 26.1)을 사용하고 있지 않은지 확인 |
| 필수 헤더 완전성 | 앱 전용 헤더가 모두 포함되어 있는지 확인 |
| 쿠키 유효성 | 저장된 세션 쿠키가 만료되지 않았는지 확인 |

### 6.3 Step 3: 외부 변화 확인

- 서비스의 보안 정책이 업데이트되었을 수 있음 (연말/연초, 대규모 업데이트)
- 우회 라이브러리의 새 버전이 필요할 수 있음
- API 엔드포인트나 필수 파라미터가 변경되었을 수 있음
- 암호화 방식이 변경되었을 수 있음 (RSA→ECC 등)

### 6.4 Step 4: 단계적 재시도

1. 가장 기본적인 요청부터 다시 시도 (requests → curl_cffi → 브라우저)
2. 각 단계에서 응답 코드와 내용을 상세히 비교
3. 필요시 Phase 1(정찰)부터 다시 시작하여 변경사항 파악

---

## 7. 법적/윤리적 주의사항

- 대상 사이트의 `robots.txt`와 이용약관을 확인하는 것이 좋다
- 과도한 요청은 서비스 방해(DoS)로 간주될 수 있다
- 수집한 데이터의 상업적 사용 시 저작권 문제가 발생할 수 있다
- 개인정보 수집 시 관련 법률(GDPR, 개인정보보호법 등)을 준수해야 한다
- 요청 간 적절한 딜레이를 넣어 서버 부하를 최소화하는 것이 좋다
