#!/usr/bin/env node
// list-blocks.js — 학습 문서의 '낭독 대상 블록'을 순서대로 나열한다.
//
// 왜 필요한가: 낭독 하이라이트는 "낭독 문단 하나 = 문서 최상위 블록 하나"라는 1:1 위에서만
// 정확하다(narration.md). 그런데 스크립트를 '귀로 듣기 좋게' 쓰다 보면 문서 구조에서 벗어나기
// 쉽다 — 제목을 읽어 주거나(제목은 블록이 아니다), 전환 신호를 독립 문단으로 빼거나,
// 문단과 그 아래 리스트를 자연스럽게 이어 읽어 하나로 합치는 식이다. 셋 다 1:1을 깨뜨린다.
//
// verify-align.js는 이것을 '사후에' 잡는다 — 음성이 이미 렌더된 뒤라 고치려면 전체 재렌더다.
// 이 스크립트는 그 검사를 '사전에' 당긴다: 스크립트를 쓰기 전에 이 목록을 뽑아 두고,
// 목록의 각 줄에 낭독 문단을 하나씩 대응시키면 1:1이 처음부터 맞는다.
//
// 사용법:
//   list-blocks.js <문서.md>              블록 목록 출력
//   list-blocks.js <문서.md> <스크립트.md> 문서 블록과 낭독 문단을 나란히 대조(어긋난 줄에 ✗)
//
// 블록 판정 규칙은 verify-align.js와 동일하다(둘이 어긋나면 검증이 무의미해지므로):
//   pre(vega-lite)→fig · 나머지 pre→code · table→table · blockquote→note · ul/ol→p · p(이미지 포함)→fig · p→p · 그 외(제목·hr)→skip

const fs = require('fs');
const path = require('path');

const docPath = process.argv[2];
const scriptPath = process.argv[3];
if (!docPath) {
  console.error('사용법: list-blocks.js <문서.md> [스크립트.md]');
  process.exit(2);
}

let parse;
try {
  const M = require(path.join(__dirname, 'vendor', 'marked.min.js'));
  parse = M.parse || (M.marked && M.marked.parse) || M.marked || M;
} catch (e) { console.error('marked 로드 실패'); process.exit(2); }

const VOID = new Set(['img','br','hr','input','meta','link','area','base','col','embed','source','track','wbr']);

function topLevelBlocks(html) {
  const re = /<(\/?)([a-zA-Z][a-zA-Z0-9]*)([^>]*?)(\/?)>/g;
  let depth = 0, m, cs = null, ct = null; const out = [];
  while ((m = re.exec(html))) {
    const isEnd = m[1] === '/', name = m[2].toLowerCase(), self = m[4] === '/' || VOID.has(name);
    if (!isEnd) {
      if (depth === 0) { cs = m.index; ct = name; }
      if (!self) depth++;
      else if (depth === 0) { out.push({ tag: name, html: m[0] }); cs = null; }
    } else {
      if (depth > 0) depth--;
      if (depth === 0 && cs !== null) { out.push({ tag: ct, html: html.slice(cs, m.index + m[0].length) }); cs = null; }
    }
  }
  return out;
}
function classify(c) {
  const t = c.tag;
  if (t === 'pre') return /language-vega-lite/.test(c.html) ? 'fig' : 'code';
  if (t === 'table') return 'table';
  if (t === 'blockquote') return 'note';
  if (t === 'ul' || t === 'ol') return 'p';
  if (t === 'p') return /<img/i.test(c.html) ? 'fig' : 'p';
  return 'skip';
}
const strip = (h, n) => h.replace(/<[^>]+>/g, ' ').replace(/&[a-z]+;/g, ' ').replace(/\s+/g, ' ').trim().slice(0, n);

const blocks = topLevelBlocks(parse(fs.readFileSync(docPath, 'utf8')))
  .map(b => ({ kind: classify(b), tag: b.tag, text: strip(b.html, 64) }))
  .filter(b => b.kind !== 'skip');

if (!scriptPath) {
  console.log(`# ${path.basename(docPath)} — 낭독 대상 블록 ${blocks.length}개`);
  console.log(`# 이 목록의 각 줄에 낭독 문단을 정확히 하나씩 대응시킨다(태그도 일치시킬 것).`);
  console.log(`# 제목(h1~h6)·구분선은 블록이 아니므로 목록에 없다 — 읽어 주는 문단을 따로 만들지 말 것.\n`);
  blocks.forEach((b, i) => console.log(`${String(i).padStart(3)} @${b.kind.padEnd(5)} [${b.tag}] ${b.text}`));
  process.exit(0);
}

// 대조 모드
const body = fs.readFileSync(scriptPath, 'utf8').split('---\n').slice(2).join('---\n');
const paras = body.trim().split('\n\n').filter(Boolean).map(p => {
  const m = p.match(/^@(\w+)\s*/);
  return { kind: m ? m[1] : 'p', text: p.replace(/^@\w+\s*/, '').replace(/\s+/g, ' ').slice(0, 64) };
});

console.log(`문서 블록 ${blocks.length}개 / 낭독 문단 ${paras.length}개` +
  (blocks.length === paras.length ? '  ✓ 개수 일치' : '  ✗ 개수 불일치'));
let bad = 0;
for (let i = 0; i < Math.max(blocks.length, paras.length); i++) {
  const b = blocks[i], p = paras[i];
  const bk = b ? b.kind : '—';
  const pk = p ? (p.kind === 'gate' ? 'note' : p.kind) : '—';
  const ok = bk === pk;
  if (!ok) bad++;
  console.log(`${ok ? '  ' : '✗ '}${String(i).padStart(3)} 문서[${bk.padEnd(5)}] ${(b ? b.text : '').padEnd(66)}| 낭독[@${(p ? p.kind : '—').padEnd(5)}] ${p ? p.text : ''}`);
}
console.log(bad ? `\n✗ 어긋난 줄 ${bad}개 — 첫 ✗ 지점부터 뒤가 전부 밀린다. 거기서부터 맞춰라.`
                : `\n✓ 1:1 정렬 온전`);
process.exit(bad ? 1 : 0);
