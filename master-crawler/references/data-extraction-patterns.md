# 데이터 추출 패턴 레퍼런스

## 1. 데이터 위치 식별

현대 SPA(Single Page Application)에서 데이터는 여러 곳에 존재할 수 있다. DOM은 "결과물"일 뿐이고, 원본 데이터는 JavaScript 변수나 네트워크 응답에 있을 가능성이 높다.

### 1.1 추출 전략 우선순위

| 우선순위 | 소스 | 장점 | 단점 |
|---------|-----|------|------|
| 1 | **API JSON 응답** | 가장 깔끔하고 완전한 데이터일 가능성이 높음 | API 발견 필요 |
| 2 | **전역 JS 변수** | SSR 초기 데이터를 확보할 수 있음 | 동적 데이터는 미포함될 수 있음 |
| 3 | **DOM 파싱** | 시각적 데이터를 추출할 수 있음 | 클래스명 변경에 매우 취약 |

---

## 2. API JSON 응답에서 추출

### 2.1 재귀적 JSON 탐색

복잡한 중첩 구조(`data` 안에 `data` 안에 `data`...)에서 원하는 패턴을 찾는 범용 함수:

```python
def extract_recursive(data, target_key):
    """재귀적으로 JSON 구조를 탐색하여 target_key를 포함하는 객체를 추출"""
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

**활용 예시**: 특정 패턴(예: `card.product` 구조)으로 상품 데이터 추출
```python
def extract_products(data):
    found = []
    if isinstance(data, dict):
        if 'card' in data and 'product' in data['card']:
            found.append(data['card']['product'])
        for value in data.values():
            found.extend(extract_products(value))
    elif isinstance(data, list):
        for item in data:
            found.extend(extract_products(item))
    return found
```

### 2.2 API 응답 구조 분석 절차

1. **디버그 파일 저장**: 캡처된 응답을 `debug_response.json`으로 저장하여 구조를 분석
2. **최상위 키 확인**: `rCode`, `rMessage`, `rData` 등의 표준 래퍼 구조를 파악
3. **데이터 배열 위치 확인**: `entityList`, `data`, `items` 등의 배열 탐색
4. **개별 항목 구조 분석**: 상품명, 가격, 이미지 URL 등의 필드명 매핑

### 2.3 복잡한 API 응답에서의 데이터 위치 패턴

API 응답은 같은 서비스 내에서도 엔드포인트마다 다른 구조를 가질 수 있다. 주의해서 분석해야 할 패턴들:

| 데이터 유형 | 가능한 JSON 경로 | 특성 |
|-----------|---------------|------|
| 광고 상품 | `entity.template.variableFacade.carouselItemVariableFacades[].variableMap` | 캐러셀 형태로 중첩이 깊을 수 있음 |
| 일반 상품 | `entity.widget.data.metadata.displayItem` | 위젯 구조 내에 위치할 수 있음 |
| 검색 결과 | `rData.entityList[].entity` | 최상위 래퍼 아래에 있을 수 있음 |
| 카테고리 목록 | `data.cards[].card.product` | 카드 구조 내에 있을 수 있음 |

**Tip**: 데이터의 정확한 위치를 모를 때, `debug_response.json`을 저장한 후 상품명이나 가격 같은 알려진 값으로 텍스트 검색하면 빠르게 경로를 파악할 수 있다.

### 2.4 광고 vs 일반 상품 구분

API 응답에는 광고 상품과 일반 상품이 혼합되어 있을 수 있다:
- `isAds: true/false` 필드 확인
- `cardType == "AD"` 등의 타입 필드 확인
- `type: "DYNAMIC_TEMPLATE"` vs `type: "UWIDGET_ENTITY"` 등 상위 타입 구분

### 2.5 페이지네이션/커서 기반 데이터

| 방식 | 파라미터 | 설명 |
|-----|---------|------|
| 페이지 번호 | `page=1&pageSize=50` | 전통적 페이지네이션 |
| 커서 | `cursor=39&pageSize=50` | 다음 페이지 키 기반 |
| 오프셋 | `offset=50&limit=50` | 오프셋 기반 |
| 다음 페이지 키 | `nextPageKey=abc123` | 서버가 제공하는 키 |

API 응답에서 `nextPageKey`, `cursor`, `hasNext`, `hasMore` 등의 필드를 찾아 다음 페이지 존재 여부를 확인할 수 있다.

---

## 3. 전역 JavaScript 변수에서 추출

### 3.1 `__NEXT_DATA__` (Next.js SSR 데이터)

Next.js 기반 사이트는 `<script id="__NEXT_DATA__">` 태그에 서버 렌더링된 초기 데이터를 포함할 수 있다.

```javascript
// 브라우저 콘솔에서 확인
const data = JSON.parse(document.getElementById('__NEXT_DATA__').textContent);
console.log(data.props.pageProps);
```

```python
# Python(Playwright/Selenium)에서 추출
next_data = driver.execute_script(
    "return JSON.parse(document.getElementById('__NEXT_DATA__').textContent)"
)
```

**한계**: 페이지 메타데이터만 포함하고 실제 데이터는 없는 경우도 있으므로 확인이 필요하다.

**페이지네이션: `_next/data` 라우트 활용**

`__NEXT_DATA__`는 첫 페이지(SSR) 데이터만 포함한다. 2페이지 이상의 데이터는 Next.js 내부 라우트 `/_next/data/{buildId}/[path].json`을 통해 가져올 수 있다.

```python
# buildId는 첫 페이지 __NEXT_DATA__에서 추출
build_id = nd['buildId']

# 2페이지 이상: _next/data 라우트 호출 (브라우저 내부 fetch)
url = f"/_next/data/{build_id}/search/all.json?query={urllib.parse.quote(keyword)}&pagingIndex=2&pagingSize=40"
result = driver.execute_script(f"""
return new Promise(function(resolve) {{
    fetch('{url}', {{headers: {{'accept': 'application/json'}}}})
    .then(function(r) {{ return r.text().then(function(t) {{ resolve({{status: r.status, text: t}}); }}); }})
    .catch(function(e) {{ resolve({{error: e.message}}); }});
}});
""")
data = json.loads(result['text'])
page_data = data['pageProps']
```

**SSR → `_next/data` 데이터 구조 변환 주의**: API 응답과 SSR/`_next/data` 응답은 같은 데이터를 다른 래퍼 구조로 반환할 수 있다. 실전 사례:

| 데이터 소스 | 상품 접근 경로 | 총 개수 접근 경로 |
|-----------|-------------|----------------|
| API (`/api/search/all`) | `shoppingResult.products[]` | `shoppingResult.total` |
| SSR (`__NEXT_DATA__`) | `props.pageProps.compositeList.list[].item` | `props.pageProps.compositeList.total` |
| `_next/data` 라우트 | `pageProps.compositeList.list[].item` | `pageProps.compositeList.total` |

`compositeList.list[]`의 각 항목은 `{item: {...실제 상품 데이터...}}` 형태로, `item` 내부의 필드(`id`, `productTitle`, `mallProductUrl`, `mallCount` 등)는 API 응답과 동일하다. 광고/일반 구분은 `item.adId` 존재 여부와 `item.isSuperSaving` 플래그로 판별할 수 있다.

### 3.2 `__next_f` (Next.js 서버-클라이언트 전달 데이터)

`window.__next_f`는 Next.js의 서버→클라이언트 데이터 전달용 배열이다. 초기 로드 데이터(보통 ~50개)를 포함할 수 있다.

```python
next_f_data = driver.execute_script("return window.__next_f")

for item in next_f_data:
    if isinstance(item, list) and len(item) >= 2:
        content = item[1]
        if '"initPagedCompositeCards"' in content:
            # 괄호 짝 맞추기로 JSON 범위 탐색
            start_marker = '"initPagedCompositeCards":'
            start_idx = content.find(start_marker)
            brace_count = 0
            for i in range(start_idx + len(start_marker), len(content)):
                if content[i] == '{': brace_count += 1
                elif content[i] == '}': brace_count -= 1
                if brace_count == 0:
                    json_str = content[start_idx:i+1]
                    data = json.loads(json_str)
                    break
```

**한계**: 초기 페이지 로드 데이터만 포함될 수 있음. 스크롤로 추가 로드된 데이터는 포함되지 않을 수 있다.

### 3.3 전역 변수 탐색 기법

어떤 전역 변수에 데이터가 있는지 모를 때, 키워드 검색으로 탐색해 볼 수 있다:

```javascript
// 브라우저 콘솔에서 실행: 특정 키워드가 포함된 전역 객체 찾기
Object.keys(window).forEach(key => {
    try {
        const val = window[key];
        if (val && typeof val === 'object') {
            const str = JSON.stringify(val);
            if (str.includes('productName') || str.includes('salePrice')) {
                console.log(key, str.length);
            }
        }
    } catch (e) {}
});
```

---

## 4. DOM 파싱 (최후의 수단)

### 4.1 왜 최후의 수단인가?

| 문제 | 설명 |
|-----|------|
| **동적 클래스명** | React/Next.js 빌드 시 해시가 붙어 매번 변경될 수 있음 (`card__TdrHT` → `card__XyZ123`) |
| **렌더링 타이밍** | JS 실행 전에 DOM을 가져오면 빈 껍데기만 획득될 수 있음 |
| **가격 파편화** | 숫자가 여러 `<span>` 태그에 분산될 수 있음 (`15` + `,` + `900`) |
| **숨겨진 데이터 누락** | 위도, 경도, 내부 ID 등 시각적으로 표시되지 않는 데이터는 추출 불가 |

### 4.2 DOM 파싱이 불가피한 경우의 전략

동적 클래스명에 강건한 선택자를 사용해 볼 수 있다:

```python
# 와일드카드 패턴으로 동적 클래스명 대응
items = await page.query_selector_all('[class*="productCard"]')

# data 속성 활용 (클래스명보다 안정적일 수 있음)
items = await page.query_selector_all('[data-shp-area="list"]')

# 구조적 선택 (태그 계층 기반)
items = await page.query_selector_all('li > a > div')
```

### 4.3 CSS Module 동적 클래스명 처리

Next.js 등 현대 프레임워크는 CSS Modules를 사용하여 빌드마다 클래스명 해시가 변경된다.

**클래스명 구조**: `ComponentName_className__randomHash`
```
ProductUnit_productUnit__Qd6sv    ← 다음 빌드에서 __Qd6sv 부분이 변경됨
ProductRating_rating__lMxS9       ← __lMxS9 부분이 변경됨
PriceArea_priceArea__NntJz        ← __NntJz 부분이 변경됨
```

**대응 전략**: `[class*="안정적인_접두사"]` 패턴으로 해시 부분을 무시한다.
```python
# 컴포넌트명_의미있는이름 까지만 매칭 (해시 무시)
items = soup.select('[class*="ProductUnit_productUnit"]')
name = item.select_one('[class*="productName"]')
price = item.select_one('[class*="priceValue"]')
rating = item.select_one('[class*="ProductRating_star"]')
```

**주의**: `[class*="price"]`처럼 너무 짧은 패턴은 의도하지 않은 요소까지 매칭할 수 있다. `ComponentName_` 접두사를 포함하면 정확도가 높아진다.

### 4.4 가격 추출 시 컨테이너 vs 구체적 요소 선택

가격 영역은 종종 중첩된 구조로 되어 있어, **컨테이너를 선택하면 의도하지 않은 텍스트가 포함**될 수 있다.

```html
<!-- 실제 DOM 구조 예시 -->
<div class="Price_price__tegCy">              ← 컨테이너 (get_text = "5,500원(1개당 1,833원)")
  <strong class="Price_priceValue__A4KOr">    ← 구체적 요소 (get_text = "5,500원") ✅
    5,500원
  </strong>
  <span>(1개당 1,833원)</span>                ← 단가 정보
</div>
```

- `[class*="Price_price"]` 선택 → `"5500(1개당 1833원)"` → 숫자 추출 시 `550011833` 오류
- `[class*="priceValue"]` 선택 → `"5,500원"` → 숫자 추출 시 `5500` 정상

**원칙**: 가격, 수량 등 수치 데이터는 가능한 한 **가장 구체적인(가장 깊은) 요소**를 선택한다.

### 4.5 API 캡처 실패 시 DOM 백업

```python
async def extract_from_dom(page):
    items = await page.query_selector_all('.item_link')
    results = []
    for item in items:
        try:
            price_el = await item.query_selector('.price')
            price = await price_el.inner_text() if price_el else None
            name_el = await item.query_selector('.name')
            name = await name_el.inner_text() if name_el else None
            results.append({"name": name, "price": price})
        except:
            continue
    return results
```

---

## 5. 하이브리드 추출 전략

초기 SSR 데이터와 동적 네트워크 데이터를 병합하면 누락을 줄일 수 있다:

```
[초기 데이터: __next_f ~50개] + [네트워크 캡처: ~950개] - [ID 기반 중복 제거] = 더 완전한 데이터셋
```

```python
def merge_and_deduplicate(initial_products, network_products):
    """ID 기반으로 중복을 제거하며 두 데이터소스 병합"""
    seen_ids = set()
    merged = []

    for product in initial_products + network_products:
        product_id = product.get('id') or product.get('productId')
        if product_id and product_id not in seen_ids:
            seen_ids.add(product_id)
            merged.append(product)

    return merged
```

---

## 6. 추출 가능한 일반적인 데이터 필드

API JSON 응답에서 자주 발견되는 필드명 패턴:

| 필드 | 타입 | 일반적인 JSON 키 |
|------|------|----------------|
| 상품 ID | string | `id`, `productId`, `itemId` |
| 상품명 | string | `name`, `productName`, `title` |
| 가격 | int | `price`, `salePrice`, `discountedPrice` |
| 원가 | int | `originalPrice`, `listPrice` |
| 할인율 | int | `discountRate`, `discount` |
| 배송비 | int | `deliveryFee`, `shippingFee` |
| 판매처 | string | `mallName`, `sellerName`, `shopName` |
| 리뷰 수 | int | `reviewCount`, `totalReviewCount` |
| 평점 | float | `rating`, `averageReviewScore` |
| 광고 여부 | bool | `isAd`, `isAds`, `cardType == "AD"` |
| 상품 URL | string | `link`, `url`, `productUrl` |
| 이미지 URL | string | `imageUrl`, `thumbnailUrl`, `image` |
| 정렬 옵션 | string | `POPULARITY`, `LOW_PRICE`, `HIGH_PRICE`, `LATEST` 등 |
