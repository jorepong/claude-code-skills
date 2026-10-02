#!/usr/bin/env node
// lint-doc.js — 학습 문서·낭독 스크립트의 품질 린트(경고만, 실패시키지 않는다)
//
// 실제 산출물에서 반복 관찰된 결함을 기계적으로 잡는다. 지침(references/*.md)이 이미
// 금지하는 것들이지만, 집필 중에는 놓치기 쉬워 build-players.sh가 매번 돌려 준다.
//
//   1. 시각 밀도 — 주요 H2가 4개 이상인데 그래픽 시각(이미지·Mermaid·Vega-Lite)이 3개 미만
//      (explanation-principles.md '시각 밀도 하한')
//   2. 상대 시점 표현 — '어제', '지난번', '09-11에'처럼 아카이브에서 뜻을 잃는 참조
//      (explanation-principles.md '채팅 없이도 읽히는 독립 교재', notation.md '다른 학습 주제')
//   3. 본문 라벨 문단 — 코드 출처를 굵은 문단으로 쓴 옛 형식(notation.md는 펜스 정보 문자열)
//   4. 낭독 전환 문장 반복 — 같은 전환 문장이 한 스크립트에서 3회 이상 (narration.md '전환 신호')
//   5. 낭독 출처 문단 — '다음 코드는 설명용 예제…'처럼 출처만 읽는 문단 (narration.md 규율 2)
//
// 사용법: lint-doc.js <문서 폴더>

const fs = require('fs');
const path = require('path');

const folder = process.argv[2];
if (!folder) { console.error('사용법: lint-doc.js <문서 폴더>'); process.exit(2); }

const files = fs.readdirSync(folder).filter(f => /^\d+-.+\.md$/.test(f));
const docs = files.filter(f => !f.endsWith('.script.md')).sort();
const scripts = files.filter(f => f.endsWith('.script.md')).sort();

let warnings = 0;
const warn = (file, msg) => { warnings++; console.log(`  ⚠ 린트 [${file}]: ${msg}`); };

function stripFences(md) {
  return md.replace(/```[\s\S]*?```/g, m => m.split('\n')[0] + '\n```');   // 펜스 본문 제거, 첫 줄(언어·출처)은 남김
}

for (const f of docs) {
  const raw = fs.readFileSync(path.join(folder, f), 'utf8');
  const md = stripFences(raw);

  // 1. 시각 밀도
  const h2 = (md.match(/^## /gm) || []).length;
  const imgs = (raw.match(/!\[[^\]]*\]\([^)]+\)/g) || []).length;
  const mermaid = (raw.match(/^```mermaid/gm) || []).length;
  const vega = (raw.match(/^```vega-lite/gm) || []).length;
  const graphics = imgs + mermaid + vega;
  if (h2 >= 4 && graphics < 3) {
    warn(f, `주요 H2 ${h2}개인데 그래픽 시각이 ${graphics}개 — 시각 커버리지 지도를 다시 훑어 A등급 누락을 채우세요(하한 3개).`);
  }
  const sims = (raw.match(/\.sim\.poster\.svg/g) || []).length;
  const anims = (raw.match(/\.anim\.poster\.svg/g) || []).length;
  if (h2 >= 4 && anims === 0 && sims === 0) {
    warn(f, `동적 시각(애니메이션·시뮬레이션)이 없습니다 — 시간·상태 변화나 입력-결과 변화가 내용에 있다면 A등급 누락입니다.`);
  }

  // 2. 상대 시점 표현
  const rel = md.match(/어제|그저께|지난번|지난주|저번에|며칠 전|엊그제|(?<![\d-])\d{2}-\d{2}에/g);
  if (rel) {
    warn(f, `상대 시점 표현 ${rel.length}곳(${[...new Set(rel)].join(', ')}) — 다른 학습 주제는 〈YYYY-MM-DD-슬러그〉 폴더명으로, 날짜는 절대 날짜로 쓰세요.`);
  }

  // 3. 옛 형식의 출처 라벨 문단
  const labels = md.match(/^\*\*(실제 코드|실제 파일 발췌|설명용 예제 코드|참조 구현|의사코드|실제 코드 기반 축약 예제|실행 명령 예제)[^\n]*\*\*\s*$/gm);
  if (labels) {
    warn(f, `코드 출처를 본문 문단으로 쓴 곳 ${labels.length}개 — 펜스 정보 문자열(example / pseudo / file= / ref= / adapted= / cmd)로 옮기고 문단을 지우세요.`);
  }
  // 출처 키워드 없는 코드 펜스
  const fences = (raw.match(/^```[^\n]*$/gm) || []).filter(l => l.length > 3);
  const openers = fences.filter((_, i) => i % 2 === 0);
  const unlabeled = openers.filter(l => !/^```(mermaid|vega-lite|pseudo|text\s*$|$)/.test(l) && !/\b(example|cmd|file=|ref=|adapted=)/.test(l));
  if (unlabeled.length) {
    warn(f, `출처 키워드 없는 코드 펜스 ${unlabeled.length}개(${unlabeled.slice(0, 3).map(l => l.replace(/^```/, '')).join(', ')}${unlabeled.length > 3 ? ' …' : ''}) — example / pseudo / file= / ref= / adapted= / cmd 중 하나를 붙이세요.`);
  }
}

for (const f of scripts) {
  const raw = fs.readFileSync(path.join(folder, f), 'utf8');
  const body = raw.split('---\n').slice(2).join('---\n');
  const paras = body.trim().split(/\n\s*\n/).filter(Boolean).map(p => p.replace(/^@\w+\s*/, '').replace(/\[\[stage:[^\]]+\]\]\s*/g, '').trim());

  // 4. 전환 문장 반복 — 각 문단의 첫 문장만 본다(전환 신호는 문단 첫머리에 온다)
  const first = paras.map(p => (p.match(/^[^.?!]*[.?!]/) || [p])[0].trim()).filter(s => /^(다시|이제|이번에는|그럼|화면|이 그림|그림을|표를|코드를)/.test(s));
  const counts = {};
  for (const s of first) counts[s] = (counts[s] || 0) + 1;
  const repeated = Object.entries(counts).filter(([, n]) => n >= 3);
  if (repeated.length) {
    warn(f, `같은 전환 문장이 반복됩니다 — ${repeated.map(([s, n]) => `"${s}" ${n}회`).join(', ')}. 문맥과 호흡에 맞춰 표현을 바꾸세요.`);
  }

  // 5. 출처만 읽는 문단
  const srcOnly = paras.filter(p => p.length < 70 && /^(다음|이번|아래|이)\S*[^.]{0,30}(설명용 예제|예제 코드|의사코드|실제 파일)/.test(p));
  if (srcOnly.length) {
    warn(f, `코드 출처만 읽는 문단 ${srcOnly.length}개("${srcOnly[0]}") — 출처는 플레이어 배지가 보여 주므로 낭독 문단을 두지 않습니다. 지우고 1:1 정렬을 다시 맞추세요.`);
  }
}

if (warnings === 0) console.log('  ✓ 문서 린트: 경고 없음');
else console.log(`  → 린트 경고 ${warnings}건. 지침은 references/explanation-principles.md · notation.md · narration.md.`);
