# 크롤링 기법 종합 레퍼런스

## 1. Level 1: HTTP 직접 요청

브라우저 없이 HTTP 클라이언트만으로 데이터를 수집하는 방법이다. 가장 빠르고 가볍지만, 봇 탐지 우회 능력이 제한적이다.

### 1.1 requests (기본)

```python
import requests

session = requests.Session()
session.headers.update({
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36...",
    "Accept": "application/json, text/plain, */*",
    "Accept-Language": "ko-KR,ko;q=0.9",
    "Referer": "https://target-site.com/",
})
response = session.get("https://target-site.com/api/data")
```

**한계**: TLS 지문이 Python 고유 패턴으로 식별되어 대부분의 봇 탐지에서 즉시 차단될 수 있다.

### 1.2 curl_cffi (TLS 지문 위장)

실제 브라우저의 TLS 핸드셰이크 패턴을 복제하여 TLS 레이어에서의 탐지를 우회해 볼 수 있다.

```python
from curl_cffi import requests as curl_requests

# Chrome 120으로 위장
session = curl_requests.Session(impersonate="chrome120")
response = session.get("https://target-site.com/api/data")

# 쿠키가 필요한 경우
response = curl_requests.get(
    url,
    cookies=session_cookies,  # 브라우저에서 추출한 쿠키
    impersonate="chrome120"
)
```

**사용 가능한 impersonate 값**:
```python
# iOS/macOS Safari
"safari15_3", "safari15_5", "safari17_0"

# Chrome (Windows/Linux/macOS)
"chrome99", "chrome100", "chrome120"

# Chrome (Android)
"chrome99_android", "chrome120_android"

# Firefox
"firefox99", "firefox120"
```

**핵심 규칙**: impersonate 값은 User-Agent와 일치시키는 것이 좋다.
- iOS 앱 위장 → `safari15_5` + iPhone User-Agent
- Android 앱 위장 → `chrome120_android` + Android User-Agent
- PC 위장 → `chrome120` + Windows User-Agent

### 1.3 모바일 API 역공학

모바일 앱의 네트워크 트래픽에서 API를 발견하고 활용하는 기법이다. 웹보다 보안이 느슨한 경우가 많아 시도해 볼 가치가 있다.

**API 발견 방법**:
1. Charles Proxy 또는 mitmproxy로 앱 트래픽 캡처
2. API 도메인(보통 `api.`, `m-api.`, `cmapi.` 등) 식별
3. 요청 헤더, 파라미터, 인증 방식 분석

**모바일 API의 장점**:
- JS 실행이 불필요한 경우가 많음
- JSON 응답으로 파싱이 용이
- 세션/쿠키 없이 헤더 인증만으로 접근 가능한 경우가 있음

**모바일 앱 위장 필수 헤더 예시**:
```python
headers = {
    "User-Agent": "AppName/9.2.0 (iPhone; iOS 17.0.3; Scale/3.00)",
    "Content-Type": "application/x-www-form-urlencoded",
    "x-app-request": "true",
    "x-accept-language": "ko-KR",
    "x-target-market": "KR",
    # 앱별 커스텀 인증 헤더 (캡처한 값 분석 필요)
}
```

### 1.4 인증 헤더 세그먼트 분석법

앱의 인증 헤더가 복잡한 구조(파이프 구분, 다수 세그먼트 등)일 때, 각 세그먼트의 실제 필수 여부를 테스트해 볼 수 있다:

**방법**: 세그먼트를 하나씩 더미 값으로 교체하면서 API 호출을 반복한다.

```python
# 예시: 28개 세그먼트로 구성된 인증 헤더
segments = original_header.split('|')
for i in range(len(segments)):
    test_segments = segments.copy()
    test_segments[i] = 'DUMMY_VALUE'  # 하나씩 더미로 교체
    test_header = '|'.join(test_segments)
    response = session.get(url, headers={"auth-header": test_header})
    print(f"Segment {i}: {'✅ 성공' if response.ok else '❌ 실패'}")
```

이 방법으로 발견할 수 있는 것들:
- **실제로 서버에서 검증되는 필수 식별자** (예: PCID, 기기 고유 ID 등)
- **더미 값으로 대체 가능한 비필수 항목** (예: 해시, UUID, 세션 정보 등)
- 핵심 식별자 하나만 유효하면 나머지는 모두 더미여도 통과하는 경우도 있었음

### 1.5 DrissionPage (CDP 기반 브라우저 자동화)

WebDriver 프로토콜 대신 **Chrome DevTools Protocol(CDP)을 직접 사용**하여 브라우저를 제어하는 도구다. Playwright+stealth, undetected-chromedriver가 모두 차단되는 사이트에서 효과적이다.

**왜 탐지를 회피하는가?**
- Selenium/Playwright는 **WebDriver 프로토콜**을 통해 브라우저를 제어한다. 이 프로토콜 자체가 자동화 흔적을 남긴다.
- stealth 플러그인은 `navigator.webdriver` 등 표면적인 속성을 숨기지만, WebDriver 프로토콜의 내부 통신 패턴까지는 숨기지 못할 수 있다.
- DrissionPage는 CDP를 직접 사용하므로 WebDriver 레이어가 아예 존재하지 않는다.
- stealth 패치 없이도 Akamai Bot Manager를 통과한 실전 사례가 있다.

**기본 사용법**:
```python
from DrissionPage import ChromiumPage, ChromiumOptions

co = ChromiumOptions()
co.set_argument('--no-sandbox')
co.auto_port()  # 자동 포트 할당 (다중 인스턴스 충돌 방지)

page = ChromiumPage(co)

# 세션 워밍업 (Akamai JS 센서 실행을 위해 메인 페이지 먼저 방문)
page.get('https://target-site.com/')
time.sleep(3)
page.scroll.down(300)  # 자연스러운 스크롤
time.sleep(1)

# 타겟 페이지 접근
page.get('https://target-site.com/category?page=1')
time.sleep(3)

# HTML 추출 → BeautifulSoup로 파싱
html = page.html
soup = BeautifulSoup(html, 'html.parser')

page.quit()
```

**브라우저 연결 끊김 재시도 패턴**:
```python
try:
    page.get(url)
except Exception:
    # 브라우저 재시작
    try:
        page.quit()
    except Exception:
        pass
    page = ChromiumPage(co)
    page.get('https://target-site.com/')  # 워밍업
    time.sleep(3)
    page.get(url)  # 재시도
```

**Windows 콘솔 UTF-8 인코딩** (한글 출력 시 cp949 에러 방지):
```python
import io, sys
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')
sys.stderr = io.TextIOWrapper(sys.stderr.buffer, encoding='utf-8', errors='replace')
```

**한계**:
- headed 모드만 안정적으로 지원 (headless는 탐지 위험 증가)
- Playwright의 `page.on('response')` 같은 네트워크 인터셉트 기능이 부족
- Node.js 기반 프론트엔드 빌드 도구와의 연동은 지원하지 않음

### 1.6 검색 API 대안 전략

특정 검색 API가 강한 인증을 요구하여 접근이 어려운 경우, 시도해 볼 수 있는 대안:

- **카테고리 API + KEYWORD 필터**: 기존 카테고리 목록 API에 검색어 필터를 추가
  ```python
  url = f"https://api.example.com/categories/{category_id}"
  payload = f"sortKeys=POPULARITY&filter=KEYWORD:{keyword}"
  ```
- **전체 검색이 아닌 카테고리 내 필터링이지만, 더 약한 인증으로 접근 가능할 수 있음**

---

## 2. Level 2: 브라우저 자동화

실제 브라우저를 프로그래밍으로 제어하여 크롤링하는 방법이다.

### 2.1 Selenium + undetected-chromedriver

```python
import undetected_chromedriver as uc

driver = uc.Chrome(use_subprocess=True)
driver.get("https://target-site.com")

# undetected-chromedriver의 주요 패치 내용:
# - cdc_ 문자열 제거 (ChromeDriver 식별자)
# - $cdc_ 전역 변수 제거
# - navigator.webdriver: true → undefined
# - enable-automation 스위치 제거
# - DevTools Protocol 탐지 명령 수정
```

**헤드리스 모드 설정** (감지가 어려운 신규 방식):
```python
options = uc.ChromeOptions()
options.add_argument("--headless=new")  # Chrome 109+ 신형 헤드리스
options.add_argument("--no-sandbox")
options.add_argument("--disable-blink-features=AutomationControlled")
```

### 2.2 Playwright + playwright-stealth

```python
from playwright.sync_api import sync_playwright
from playwright_stealth import stealth_sync

with sync_playwright() as p:
    browser = p.chromium.launch(headless=False)
    context = browser.new_context(
        viewport={'width': 1280, 'height': 720},
        user_agent='Mozilla/5.0 ...'
    )
    page = context.new_page()
    stealth_sync(page)  # 자동화 흔적 제거 (goto 전에 호출)

    page.goto('https://target-site.com')
```

**playwright-stealth이 숨기는 것**:
- `navigator.webdriver` 속성
- Chrome DevTools Protocol 탐지
- 헤드리스 브라우저 특성
- 플러그인/Permission 정보 정상화

### 2.3 하이브리드 방식 (브라우저 로그인 + HTTP 크롤링)

효율적인 전략: 브라우저로 1회 세션을 생성한 후, 빠른 HTTP 요청으로 대량 수집을 시도.

```
1단계: 브라우저로 세션 생성 (1회, 10~15초)
  → 봇 탐지 쿠키 획득
  → 쿠키를 파일로 저장

2단계: HTTP 클라이언트로 크롤링 (무제한, 페이지당 1~2초)
  → 저장된 쿠키를 curl_cffi에 주입
  → 세션 만료 시(약 30분 정도일 수 있음) 1단계 재실행
```

```python
# 쿠키 추출 (Playwright)
cookies = context.cookies()
with open('session.json', 'w') as f:
    json.dump(cookies, f)

# 쿠키 주입 (curl_cffi)
with open('session.json', 'r') as f:
    cookies = json.load(f)

session = curl_requests.Session(impersonate="chrome120")
for cookie in cookies:
    session.cookies.set(cookie['name'], cookie['value'], domain=cookie['domain'])
```

### 2.4 세션 워밍업

일부 사이트에서는 바로 타겟 페이지에 접근하면 의심을 유발할 수 있다. 이런 경우:
1. 메인 페이지를 먼저 방문하여 기본 쿠키를 획득
2. 인간처럼 잠시 스크롤 후 카테고리로 이동
3. 타겟 페이지에 도달

이 과정이 봇 탐지 우회에 도움이 될 수 있다.

### 2.5 헤드리스 모드에서의 텍스트 입력

헤드리스 모드에서 클립보드 붙여넣기(Ctrl+V)가 작동하지 않는 경우, **CDP(Chrome DevTools Protocol) `Input.insertText`**를 시도해 볼 수 있다:

```python
def input_text_cdp(driver, element, text):
    """CDP로 텍스트 직접 입력 (헤드리스 호환)"""
    element.click()
    time.sleep(0.2)

    # 기존 내용 삭제 (Ctrl+A → Delete)
    driver.execute_cdp_cmd("Input.dispatchKeyEvent", {
        "type": "keyDown", "windowsVirtualKeyCode": 65, "modifiers": 2  # Ctrl+A
    })
    driver.execute_cdp_cmd("Input.dispatchKeyEvent", {
        "type": "keyUp", "windowsVirtualKeyCode": 65, "modifiers": 2
    })
    driver.execute_cdp_cmd("Input.dispatchKeyEvent", {
        "type": "keyDown", "windowsVirtualKeyCode": 46  # Delete
    })
    driver.execute_cdp_cmd("Input.dispatchKeyEvent", {
        "type": "keyUp", "windowsVirtualKeyCode": 46
    })

    # 텍스트 직접 입력
    driver.execute_cdp_cmd("Input.insertText", {"text": text})
```

---

## 3. Level 3: 네트워크 캡처

브라우저가 정상적으로 수행하는 API 요청의 응답을 가로채는 방법이다. 가장 견고하고 성공률이 높을 수 있다.

### 3.1 Playwright Response Intercept

```python
class NetworkCaptureCrawler:
    def __init__(self, api_pattern='/api/'):
        self.api_pattern = api_pattern
        self.captured_responses = []

    async def _on_response(self, response):
        if self.api_pattern in response.url and response.status == 200:
            content_type = response.headers.get('content-type', '')
            if 'application/json' in content_type:
                try:
                    data = await response.json()
                    self.captured_responses.append({
                        'url': response.url,
                        'data': data
                    })
                except:
                    pass

    async def crawl(self, url, wait_seconds=3.0):
        async with async_playwright() as p:
            browser = await p.chromium.launch(headless=True)
            page = await browser.new_page()
            page.on('response', self._on_response)
            await page.goto(url, wait_until='networkidle')
            await asyncio.sleep(wait_seconds)
            await browser.close()
        return self.captured_responses
```

**왜 성공률이 높을 수 있는가?**
1. 브라우저가 직접 API를 호출하므로 모든 인증 토큰이 자동 포함됨
2. 요청을 조작하지 않고 이미 성공한 응답만 캡처
3. 실제 사용자와 동일한 TLS 지문, JS 실행 환경

### 3.2 Fetch Monkey Patching

브라우저의 `window.fetch`를 래퍼 함수로 교체하여 모든 네트워크 응답을 투명하게 가로채 볼 수 있다.

```javascript
// 브라우저에 주입하는 JavaScript
if (!window.capturedRequests) {
    window.capturedRequests = [];
    const originalFetch = window.fetch;

    window.fetch = async (...args) => {
        const response = await originalFetch(...args);
        const clone = response.clone();

        try {
            const json = await clone.json();
            const url = args[0] instanceof Request ? args[0].url : args[0];

            if (url.includes('search') || url.includes('/api/')) {
                window.capturedRequests.push({ url: url, data: json });
            }
        } catch (e) { /* JSON이 아닌 응답 무시 */ }

        return response;  // 원래 응답 반환 (브라우저 정상 동작)
    };
}
```

**동작 흐름**:
```
사용자 스크롤/클릭 → 브라우저 fetch() 호출 → 래퍼 함수가 가로챔
→ 원본 fetch 실행 → 응답을 capturedRequests에 복사
→ 원본 응답을 브라우저에 전달 (정상 렌더링)
```

**Python에서 데이터 회수**:
```python
captured = driver.execute_script("return window.capturedRequests")
```

### 3.3 무한 스크롤 처리

물리적 스크롤이 봇 탐지를 우회하는 가장 안정적인 방법일 수 있다:

```python
def human_like_scroll(driver, scroll_count=20):
    for i in range(scroll_count):
        scroll_amount = random.randint(200, 500)
        driver.execute_script(f"""
            window.scrollTo({{
                top: document.documentElement.scrollTop + {scroll_amount},
                behavior: 'smooth'
            }});
        """)
        time.sleep(random.uniform(1.0, 2.0))
```

**주의**: 일부 사이트는 API 요청이 스크롤 이벤트에 의해 트리거되었는지 검증할 수 있다. JavaScript로 직접 fetch 루프를 돌리면 봇으로 감지될 수 있다 (isTrusted 이벤트 속성 검증 등).

| 방식 | 속도 | 성공률 (실전 경험) |
|-----|------|-----------------|
| 물리적 스크롤 + 네트워크 캡처 | 느림 (30초) | **100%** |
| JS fetch 루프 | 빠름 (1초) | **5%** |
| 브라우저 외부 API 호출 | 최고속 | **0%** |

### 3.4 브라우저 내부 JS fetch (특정 조건에서 가능)

일부 사이트에서는 브라우저 내에서 JS fetch를 직접 호출해도 성공할 수 있다.

```python
result = driver.execute_script("""
    return (async () => {
        const url = '/api/data?cursor=0&pageSize=50&query=' +
            encodeURIComponent(keyword);
        const response = await fetch(url, {
            method: 'GET',
            credentials: 'include'
        });
        if (!response.ok) return { error: response.status };
        return await response.json();
    })();
""")
```

**주의**: 헤드리스 모드에서는 같은 코드가 418 에러를 반환할 수 있다. 이 경우 curl_cffi로 대체해 볼 수 있다:

```python
if headless_mode:
    # 헤드리스: curl_cffi 사용을 시도
    response = curl_requests.get(api_url, cookies=cookies, impersonate="chrome120")
else:
    # 일반 모드: 브라우저 내 JS fetch를 시도
    result = driver.execute_script("return (async () => { ... })()")
```

### 3.5 Next.js `_next/data` 라우트를 통한 데이터 수집

Next.js 사이트에서 API 엔드포인트가 ncaptcha 등 강한 토큰 인증으로 보호될 때, **`_next/data` 내부 라우트**를 브라우저 세션 내에서 호출하면 토큰 없이 동일한 데이터를 얻을 수 있다. 이 방식은 네이버 쇼핑 검색 API가 ncaptcha WASM 토큰으로 보호된 후 실전에서 검증되었다.

**원리**: Next.js는 클라이언트 사이드 네비게이션 시 `/_next/data/{buildId}/[...path].json` 경로로 내부 데이터를 가져온다. 이 라우트는 API 엔드포인트와 다른 경로이므로 별도의 토큰 검증이 적용되지 않을 수 있다. 브라우저 내부에서 same-origin fetch로 호출하므로 쿠키와 세션이 자동으로 포함된다.

**구현 패턴**:
```python
import json, urllib.parse

# 1단계: SSR 페이지에서 buildId 추출
driver.get(f"https://example.com/search?query={urllib.parse.quote(keyword)}")
nd_raw = driver.execute_script(
    "var el = document.getElementById('__NEXT_DATA__'); return el ? el.textContent : null;"
)
nd = json.loads(nd_raw)
build_id = nd['buildId']
first_page_data = nd['props']['pageProps']  # 첫 페이지 데이터는 SSR에서 직접 추출

# 2단계: 2페이지 이상은 _next/data 라우트로 fetch
next_data_url = f"/_next/data/{build_id}/search.json?query={urllib.parse.quote(keyword)}&page=2"
result = driver.execute_script(f"""
return new Promise(function(resolve) {{
    fetch('{next_data_url}', {{headers: {{'accept': 'application/json'}}}})
    .then(function(r) {{ return r.text().then(function(text) {{ resolve({{status: r.status, text: text}}); }}); }})
    .catch(function(e) {{ resolve({{error: e.message}}); }});
}});
""")
page_data = json.loads(result['text'])['pageProps']
```

**주의사항**:
- `buildId`는 Next.js 빌드마다 변경된다. 매 세션 시작 시 첫 페이지에서 추출해야 한다.
- 페이지 1은 SSR `__NEXT_DATA__`에서, 페이지 2+는 `_next/data` 라우트에서 가져오는 하이브리드 방식이 효율적이다.
- 데이터 구조가 API 응답과 다를 수 있다 (예: `shoppingResult.products[]` → `compositeList.list[].item`). 같은 필드이지만 래퍼 구조가 다르므로 파서를 적절히 조정해야 한다.
- `window.fetch` 오버라이드(Monkey Patching)로는 Next.js 내부 라우팅 호출을 캡처하지 못할 수 있다. Next.js가 내부적으로 캐시된 fetch 참조를 사용하거나 내부 라우터를 통해 호출하기 때문이다. 직접 `driver.execute_script(fetch(...))` 로 명시적으로 호출하는 것이 더 확실하다.

**성능** (실전 측정):
- SSR `__NEXT_DATA__` 추출: ~0.6초/페이지 (페이지 로드 포함)
- `_next/data` 라우트 fetch: ~0.5초/페이지 (네트워크 요청만)
- 페이지당 약 40개 상품, 총 개수 정확하게 반환

### 3.6 한글 키워드 인코딩 주의

Python에서 JavaScript로 한글 문자열을 전달할 때 `json.dumps()`를 사용하여 안전하게 인코딩하는 것이 좋다:

```python
import json
keyword_json = json.dumps(keyword)  # '"갤럭시 s25"' (따옴표 포함)

result = driver.execute_script(f"""
    const keyword = {keyword_json};
    const url = '/api/search?query=' + encodeURIComponent(keyword);
    // ...
""")
```

---

## 4. 성능 비교 종합

| 방법 | 세션 생성 | 페이지당 속도 | 100페이지 | 리소스 | 성공 가능성 |
|-----|---------|------------|---------|-------|-----------|
| 모바일 API (세션 없음) | 0초 | 0.5~1초 | 1~2분 | 매우 낮음 | 상황에 따라 다름 |
| **DrissionPage (CDP 직접)** | 3~5초 | 3~5초 | 5~8분 | 중간 | **매우 높음** |
| 하이브리드 (세션+HTTP) | 10~15초 | 1~2초 | 2~3분 | 낮음 | 높을 수 있음 |
| **`_next/data` 라우트 (브라우저 내)** | 10~15초 | 0.5~0.6초 | 1분 | 중간 | **매우 높음** (ncaptcha 우회) |
| 브라우저 내 JS fetch | 10~15초 | 0.3초 | 1분 | 중간 | 중~높을 수 있음 |
| 브라우저 전용 (스크롤) | 매 요청 | 3~5초 | 5~8분 | 높음 | 매우 높을 수 있음 |
| 네트워크 캡처 | 10~15초 | 1.5초 | 3분 | 중간 | 매우 높을 수 있음 |
