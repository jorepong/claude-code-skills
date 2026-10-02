#!/usr/bin/env python3
"""review_queue.py — learn 스킬의 인출 카드 큐(간격 복습).

한 번 배운 것을 다시 배우지 않게 하는 장치다. 각 학습 주제가 끝날 때 핵심 판정 기준·인과를
인출 카드로 뽑아 전역 큐에 넣고, 복습 세션에서 기한이 된 카드를 주제를 섞어 묻는다.
학습자의 답에 대한 등급으로 다음 기한을 간격 사다리로 정한다(references/retention.md).

큐 파일: ~/.claude/learn/review/queue.jsonl (한 줄 = 카드 하나, JSON)

사용법:
  review_queue.py add <카드 파일.jsonl|.md>      카드 추가(마크다운이면 '## Q' 블록 형식, 아래 참고)
  review_queue.py due [--limit N] [--all]        오늘 기한인 카드를 주제 교차 순서로 출력
  review_queue.py grade <id> <0|1|2> [메모]      답 등급 기록 → 다음 기한 갱신
  review_queue.py stats                          주제별 카드 수·기한·정착 상태
  review_queue.py show <id>                      카드 하나 상세

마크다운 카드 파일 형식(주제 폴더의 review-cards.md):
  topic: 2026-09-27-sql-regex
  ---
  ## Q 정규식의 기본 판정은 LIKE와 어떻게 반대인가?
  kind: recall
  doc: 01-정규식이-문자열을-판정하는-방식.md
  A: LIKE는 전체 일치가 기본이고 포함을 원하면 %를 붙인다. 정규식은 포함이 기본이고 ...

등급: 0 = 꺼내지 못함 / 핵심이 틀림 · 1 = 힌트나 부분만 · 2 = 자료 없이 정확히 꺼냄
"""
import json, os, sys, re, datetime, hashlib

LADDER = [1, 3, 7, 14, 30, 60, 120]   # 등급 2마다 한 칸 위로, 1은 제자리, 0은 맨 아래
QUEUE = os.path.join(os.path.expanduser(os.environ.get('LEARN_ARCHIVE_ROOT', '~/.claude/learn')), 'review', 'queue.jsonl')


def today():
    return datetime.date.today()


def load():
    if not os.path.exists(QUEUE):
        return []
    with open(QUEUE, encoding='utf-8') as f:
        return [json.loads(l) for l in f if l.strip()]


def save(cards):
    os.makedirs(os.path.dirname(QUEUE), exist_ok=True)
    tmp = QUEUE + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        for c in cards:
            f.write(json.dumps(c, ensure_ascii=False) + '\n')
    os.replace(tmp, QUEUE)


def make_id(topic, question):
    return hashlib.sha1((topic + '\n' + question).encode('utf-8')).hexdigest()[:8]


def parse_md(path):
    text = open(path, encoding='utf-8').read()
    head, _, body = text.partition('\n---\n')
    topic = None
    for line in head.splitlines():
        m = re.match(r'\s*topic:\s*(.+)', line)
        if m:
            topic = m.group(1).strip()
    if not topic:
        topic = os.path.basename(os.path.dirname(os.path.abspath(path)))
    cards = []
    for block in re.split(r'^## Q\s*', body, flags=re.M)[1:]:
        lines = block.strip().splitlines()
        question = lines[0].strip()
        kind, doc, answer = 'recall', '', []
        in_answer = False
        for l in lines[1:]:
            if in_answer:
                answer.append(l)
                continue
            m = re.match(r'(kind|doc|A):\s*(.*)', l)
            if not m:
                continue
            k, v = m.group(1), m.group(2)
            if k == 'kind':
                kind = v.strip()
            elif k == 'doc':
                doc = v.strip()
            else:
                answer.append(v)
                in_answer = True
        cards.append({'topic': topic, 'question': question, 'kind': kind, 'doc': doc,
                      'answer': '\n'.join(answer).strip()})
    return cards


def cmd_add(path):
    new = parse_md(path) if path.endswith('.md') else [json.loads(l) for l in open(path, encoding='utf-8') if l.strip()]
    cards = load()
    ids = {c['id'] for c in cards}
    added = 0
    for c in new:
        c['id'] = make_id(c['topic'], c['question'])
        if c['id'] in ids:
            continue
        c.setdefault('kind', 'recall')
        c.update({'created': today().isoformat(), 'due': (today() + datetime.timedelta(days=LADDER[0])).isoformat(),
                  'rung': 0, 'reps': 0, 'lapses': 0, 'history': []})
        cards.append(c)
        ids.add(c['id'])
        added += 1
    save(cards)
    print(f'카드 {added}개 추가(중복 {len(new) - added}개 건너뜀) → {QUEUE}')
    print(f'첫 복습 기한: {(today() + datetime.timedelta(days=LADDER[0])).isoformat()}')


def interleave(cards):
    """주제별로 묶은 뒤 라운드로빈으로 섞는다 — 같은 주제가 연달아 나오지 않게."""
    by = {}
    for c in cards:
        by.setdefault(c['topic'], []).append(c)
    for v in by.values():
        v.sort(key=lambda c: (c['due'], c['rung']))
    out = []
    while any(by.values()):
        for t in sorted(by, key=lambda t: by[t][0]['due'] if by[t] else '9'):
            if by[t]:
                out.append(by[t].pop(0))
    return out


def cmd_due(args):
    limit = 8
    show_all = '--all' in args
    if '--limit' in args:
        limit = int(args[args.index('--limit') + 1])
    cards = load()
    t = today().isoformat()
    due = [c for c in cards if show_all or c['due'] <= t]
    if not due:
        nxt = min((c['due'] for c in cards), default=None)
        print('오늘 기한인 카드가 없습니다.' + (f' 다음 기한: {nxt}' if nxt else ' 큐가 비어 있습니다.'))
        return
    due = interleave(due)
    print(f'기한 카드 {len(due)}개 중 {min(limit, len(due))}개 (주제 교차 순서). 등급은 grade <id> <0|1|2>.')
    for c in due[:limit]:
        overdue = (today() - datetime.date.fromisoformat(c['due'])).days
        print(f"\n[{c['id']}] {c['topic']} · {c['kind']} · 사다리 {c['rung']} · 기한 {c['due']}" + (f' (+{overdue}일)' if overdue > 0 else ''))
        print(f"  Q: {c['question']}")
        print(f"  A: {c['answer']}")
        if c.get('doc'):
            print(f"  doc: {c['doc']}")


def cmd_grade(cid, grade, note=''):
    grade = int(grade)
    assert grade in (0, 1, 2), '등급은 0·1·2'
    cards = load()
    for c in cards:
        if c['id'] == cid:
            if grade == 2:
                c['rung'] = min(c['rung'] + 1, len(LADDER) - 1)
            elif grade == 0:
                c['rung'] = 0
                c['lapses'] += 1
            c['reps'] += 1
            c['due'] = (today() + datetime.timedelta(days=LADDER[c['rung']])).isoformat()
            c['history'].append({'date': today().isoformat(), 'grade': grade, 'note': note})
            save(cards)
            print(f"[{cid}] 등급 {grade} → 다음 기한 {c['due']} (사다리 {c['rung']}, {LADDER[c['rung']]}일 뒤)")
            return
    sys.exit(f'카드를 찾지 못했습니다: {cid}')


def cmd_stats():
    cards = load()
    if not cards:
        print('큐가 비어 있습니다.'); return
    t = today().isoformat()
    by = {}
    for c in cards:
        s = by.setdefault(c['topic'], {'n': 0, 'due': 0, 'settled': 0, 'lapses': 0})
        s['n'] += 1
        s['due'] += c['due'] <= t
        s['settled'] += c['rung'] >= 3   # 14일 이상 간격에 올라간 카드 = 정착 중
        s['lapses'] += c['lapses']
    print(f"{'주제':46} {'카드':>4} {'기한':>4} {'정착':>4} {'실패':>4}")
    for tp, s in sorted(by.items()):
        print(f"{tp[:46]:46} {s['n']:4} {s['due']:4} {s['settled']:4} {s['lapses']:4}")
    print(f"\n전체 {len(cards)}장 · 오늘 기한 {sum(c['due'] <= t for c in cards)}장")


def cmd_show(cid):
    for c in load():
        if c['id'] == cid:
            print(json.dumps(c, ensure_ascii=False, indent=2)); return
    sys.exit('없음')


if __name__ == '__main__':
    a = sys.argv[1:]
    if not a or a[0] in ('-h', '--help'):
        print(__doc__); sys.exit(0)
    cmd = a[0]
    if cmd == 'add': cmd_add(a[1])
    elif cmd == 'due': cmd_due(a[1:])
    elif cmd == 'grade': cmd_grade(a[1], a[2], ' '.join(a[3:]))
    elif cmd == 'stats': cmd_stats()
    elif cmd == 'show': cmd_show(a[1])
    else: sys.exit(f'알 수 없는 명령: {cmd}\n{__doc__}')
