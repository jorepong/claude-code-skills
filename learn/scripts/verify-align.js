#!/usr/bin/env node
// verify-align.js — 낭독 하이라이트 1:1 정렬 검증
//
// player.html은 "낭독 문단 하나 = 문서 최상위 블록 하나"라는 1:1 가정 위에서
// 재생 위치에 맞춰 문서 블록을 하이라이트한다. 이 1:1이 어긋나면(문단을 합치거나
// 나누면) 하이라이트가 낭독과 밀린다. 이 스크립트는 각 섹션에 대해:
//   - 문서(NN-*.md)를 marked로 렌더해 브라우저와 '같은' 최상위 블록 순서를 뽑고,
//   - 낭독 큐(audio/NN.cues.json)를 그 블록 순서에 매핑해,
//   - 문단 수 ≠ (heading 제외) 블록 수 이거나 매핑에 구멍이 있으면 경고한다.
// 기본은 경고만 하며, --strict를 주면 정렬 문제를 실패로 반환한다.

const fs = require('fs');
const path = require('path');

const folder = process.argv[2];
const artifactRoot = process.argv[3] && process.argv[3] !== '--strict'
  ? process.argv[3] : folder;
const strict = process.argv.includes('--strict');
if (!folder) {
  console.error('사용법: verify-align.js <원본 폴더> [산출물 폴더] [--strict]');
  process.exit(2);
}

let parse;
try {
  const M = require(path.join(__dirname, 'vendor', 'marked.min.js'));
  parse = M.parse || (M.marked && M.marked.parse) || M.marked || M;
} catch (e) { console.log('(marked 로드 실패 — 정렬 검증 건너뜀)'); process.exit(0); }

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

const glob = (dir, re) => fs.existsSync(dir) ? fs.readdirSync(dir).filter(f => re.test(f)) : [];
const cueFiles = glob(path.join(artifactRoot, 'audio'), /^\d+\.cues\.json$/).sort();
if (cueFiles.length === 0) process.exit(0);

let problems = 0;
for (const cf of cueFiles) {
  const nn = cf.split('.')[0];
  const docName = fs.readdirSync(folder).find(f => f.startsWith(nn + '-') && f.endsWith('.md') && !f.endsWith('.script.md'));
  if (!docName) {
    problems++;
    console.log(`  ⚠ 정렬 경고 [${nn}]: 대응 학습 문서를 찾지 못했습니다.`);
    continue;
  }
  const html = parse(fs.readFileSync(path.join(folder, docName), 'utf8'));
  const blocks = topLevelBlocks(html);
  const kinds = blocks.map(classify);
  const nonSkip = kinds.filter(k => k !== 'skip').length;
  let cues;
  try {
    cues = JSON.parse(fs.readFileSync(path.join(artifactRoot, 'audio', cf), 'utf8'));
  } catch (e) {
    problems++;
    console.log(`  ⚠ 정렬 경고 [${nn}]: cue JSON을 읽지 못했습니다: ${e.message}`);
    continue;
  }

  const issues = [];
  if (cues.length !== nonSkip) {
    issues.push(`문단 ${cues.length}개 ≠ 문서 블록 ${nonSkip}개 — 하이라이트가 낭독과 어긋납니다(문단을 합치거나 나눴을 가능성; 1:1로 맞추세요).`);
  }
  let ptr = 0;
  cues.forEach((c, i) => {
    const want = c.type === 'gate' ? 'note' : c.type;
    let found = null;
    for (let j = ptr; j < kinds.length; j++) { if (kinds[j] === want) { found = j; ptr = j + 1; break; } }
    if (found === null) issues.push(`큐 ${i}(@${c.type})가 대응할 문서 블록(${want})을 못 찾음.`);
  });

  if (issues.length) {
    problems++;
    console.log(`  ⚠ 정렬 경고 [${nn}]: ${issues.join(' / ')}`);
  } else {
    console.log(`  ✓ 정렬 확인 [${nn}]: 문단 ${cues.length} = 블록 ${nonSkip}, 매핑 온전`);
  }
}
if (problems) console.log('  → 위 섹션의 낭독 스크립트를 "문단 하나 = 문서 블록 하나"로 다시 맞추세요(narration.md).');
if (problems && strict) process.exit(1);
