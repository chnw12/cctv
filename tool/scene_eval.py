"""공개 기계실 사진으로 AI(Gemini) 위험 판단을 반복 시험하기(일관성·사람 정답 비교).

순서
  1) 후보 찾기(위키미디어 공용, 사용 허락이 분명한 사진만 — 메타데이터만 읽음, 사진은 안 받음)
       python tool/scene_eval.py search
     → build/scene_eval/candidates.csv (번호·제목·라이선스·작성자·크기·주소)
  2) 고른 후보만 받기(긴 변 1024px로 줄여 저장 = 앱이 AI에 보내는 크기)
       python tool/scene_eval.py fetch 3 7 12 ...
     → build/scene_eval/images/NN_이름.jpg, sources.csv(출처 표기용), answers.csv(팀 정답 적는 표, 없을 때만 만듦)
  3) 팀이 사진을 보고 answers.csv에 "사람이 본 위험"을 먼저 적음(AI 결과를 보기 전에!)
  4) AI 반복 시험(키는 secrets.json, 화면·로그에 출력 안 함)
       flutter test test/scene_eval_test.dart --dart-define-from-file=secrets.json -r expanded
     → build/scene_eval/results.jsonl, annotated/*.png
  5) 보고서(모델 하나) / 비교(Claude 결과가 있으면)
       python tool/scene_eval.py report   [--file results_claude-opus-5-5.jsonl]
       python tool/scene_eval.py compare  → build/scene_eval/compare.md (Gemini vs Claude: 일관성·속도·박스·비용·짚은 위험 차이)
     → build/scene_eval/report.md (같은 사진 반복 시 등급 일치율, 사람 정답 대비 AI가 짚은 것·더 짚은 것)

사진은 build/ 아래(저장소에 안 올라감)에 둡니다. 리포트에 사진을 실을 때는 sources.csv의 작성자·라이선스를 함께 적으세요.
필요한 것: 파이썬 3 + Pillow(fetch 때만).
"""
import argparse
import csv
import html
import json
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / 'build' / 'scene_eval'
API = 'https://commons.wikimedia.org/w/api.php'
UA = 'facility-camera-scene-eval/0.1 (internal test script)'
LONG_SIDE = 1024  # 앱이 AI에 보내는 사진 긴 변

# 기계실·전기실에서 사람이 놓치기 쉬운 장면 + 깨끗한 장면(헛알림 확인용)
QUERIES = [
    'boiler room', 'mechanical room', 'plant room pipes', 'pump room', 'electrical room',
    'switchboard room', 'basement pipes', 'leaking pipe', 'water leak basement', 'rusty pipes',
    'corroded pipe', 'cluttered basement', 'cluttered storage room', 'open electrical panel',
    'fuse box wiring', 'cable tray', 'HVAC plant room', 'chiller plant', 'fire extinguisher',
    'flooded basement',
]
FREE = re.compile(r'^(CC0|CC BY(-SA)? [\d.]+|Public domain|PD|CC BY-SA|CC BY)', re.I)


def api(params):
    q = urllib.parse.urlencode({**params, 'format': 'json', 'formatversion': 2})
    req = urllib.request.Request(f'{API}?{q}', headers={'User-Agent': UA})
    for wait in (5, 15, 30, None):  # 너무 자주 물으면 429 → 점점 길게 쉬고 다시
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                return json.load(r)
        except urllib.error.HTTPError as e:
            if e.code != 429 or wait is None:
                raise
            time.sleep(wait)


def text(v):
    """메타데이터 HTML → 한 줄 글자"""
    return re.sub(r'\s+', ' ', html.unescape(re.sub(r'<[^>]+>', ' ', v or ''))).strip()


def search(args):
    OUT.mkdir(parents=True, exist_ok=True)
    seen, rows = set(), []
    for q in args.queries or QUERIES:
        try:
            data = api({
                'action': 'query', 'generator': 'search', 'gsrsearch': f'{q} filetype:bitmap',
                'gsrnamespace': 6, 'gsrlimit': args.per, 'prop': 'imageinfo',
                'iiprop': 'url|size|mime|extmetadata', 'iiurlwidth': LONG_SIDE,
                'iiextmetadatafilter': 'LicenseShortName|Artist|LicenseUrl|ImageDescription',
            })
        except Exception as e:  # noqa: BLE001 — 검색어 하나가 실패해도 계속
            print(f'[{q}] 실패: {e}', file=sys.stderr)
            time.sleep(5)
            continue
        for p in (data.get('query') or {}).get('pages', []):
            ii = (p.get('imageinfo') or [{}])[0]
            meta = ii.get('extmetadata') or {}
            lic = text(meta.get('LicenseShortName', {}).get('value'))
            if p['title'] in seen or ii.get('mime') not in ('image/jpeg', 'image/png'):
                continue
            if not FREE.match(lic) or min(ii.get('width', 0), ii.get('height', 0)) < 600:
                continue
            seen.add(p['title'])
            rows.append({
                'id': len(rows) + 1, 'query': q, 'title': p['title'],
                'size': f"{ii['width']}x{ii['height']}", 'license': lic,
                'artist': text(meta.get('Artist', {}).get('value'))[:80],
                'license_url': text(meta.get('LicenseUrl', {}).get('value')),
                'page': ii.get('descriptionurl', ''), 'thumb': ii.get('thumburl', ''),
                'desc': text(meta.get('ImageDescription', {}).get('value'))[:160],
            })
        time.sleep(2)
    path = OUT / 'candidates.csv'
    with path.open('w', newline='', encoding='utf-8-sig') as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()) if rows else ['id'])
        w.writeheader()
        w.writerows(rows)
    for r in rows:
        print(f"{r['id']:>3} | {r['query']:<22} | {r['title'][5:70]:<65} | {r['size']:>9} | {r['license']}")
    print(f'\n후보 {len(rows)}개 → {path}')


def fetch(args):
    from PIL import Image  # fetch 때만 필요
    import io

    rows = {int(r['id']): r for r in csv.DictReader((OUT / 'candidates.csv').open(encoding='utf-8-sig'))}
    img_dir = OUT / 'images'
    img_dir.mkdir(parents=True, exist_ok=True)
    src_path = OUT / 'sources.csv'
    sources = list(csv.DictReader(src_path.open(encoding='utf-8-sig'))) if src_path.exists() else []
    have = {s['title'] for s in sources}
    n = len(sources)
    for i in args.ids:
        r = rows[i]
        if r['title'] in have:
            print(f'{i}: 이미 받음')
            continue
        req = urllib.request.Request(r['thumb'], headers={'User-Agent': UA})
        with urllib.request.urlopen(req, timeout=60) as resp:
            raw = resp.read()
        im = Image.open(io.BytesIO(raw)).convert('RGB')
        s = LONG_SIDE / max(im.size)
        if s < 1:
            im = im.resize((round(im.width * s), round(im.height * s)), Image.LANCZOS)
        n += 1
        stem = re.sub(r'[^0-9A-Za-z]+', '_', Path(r['title'][5:]).stem)[:40].strip('_')
        name = f'{n:02d}_{stem}.jpg'
        im.save(img_dir / name, 'JPEG', quality=85)
        sources.append({'file': name, 'title': r['title'], 'artist': r['artist'],
                        'license': r['license'], 'license_url': r['license_url'], 'page': r['page']})
        print(f'{i} → {name} ({im.width}x{im.height}, {(img_dir / name).stat().st_size // 1024}KB, {r["license"]})')
        time.sleep(0.5)
    with src_path.open('w', newline='', encoding='utf-8-sig') as f:
        w = csv.DictWriter(f, fieldnames=['file', 'title', 'artist', 'license', 'license_url', 'page'])
        w.writeheader()
        w.writerows(sources)
    ans = OUT / 'answers.csv'
    if not ans.exists():
        with ans.open('w', newline='', encoding='utf-8-sig') as f:
            w = csv.writer(f)
            w.writerow(['file', '사람이 본 위험(종류를 ;로)', '최고 등급(high/medium/low/없음)', '메모'])
            for s in sources:
                w.writerow([s['file'], '', '', ''])
        print(f'정답표 → {ans} (AI 결과를 보기 전에 팀이 채우기)')
    else:
        known = {r['file'] for r in csv.DictReader(ans.open(encoding='utf-8-sig'))}
        with ans.open('a', newline='', encoding='utf-8-sig') as f:
            w = csv.writer(f)
            for s in sources:
                if s['file'] not in known:
                    w.writerow([s['file'], '', '', ''])


# 위험 종류(자유 문장) → 대략적인 분류. 지시문의 예시 목록 기준, 위에서부터 먼저 맞는 것
CATEGORIES = [
    ('누수·누유', ['누수', '누유', '물기', '물고임', '물 고임', '고인 물', '웅덩이', '젖', '샘', '새는', '기름']),
    ('연기·화재', ['연기', '그을음', '화재', '불꽃', '탄 자국']),
    ('회전체', ['회전', '보호커버', '보호 커버', '벨트', '팬 커버']),
    # "소화기 앞 적치물"·"분전반 앞 적치물"은 막힘이 핵심이라 소화설비·전기보다 먼저
    ('적치·장애물', ['적치', '장애물', '방치', '쌓', '널', '부품', '자재', '물건', '통로', '정리', '걸려', '넘어']),
    ('소화설비', ['소화기', '소화전', '소화']),
    ('전기 노출', ['전선', '배선', '분전반', '충전부', '단자', '케이블', '콘센트', '전기', '차단기']),
    ('부식·녹', ['부식', '녹', '산화']),
    ('미끄럼', ['미끄']),
    ('계기', ['계기', '압력계', '게이지', '온도계', '눈금']),
    ('보호구', ['보호구', '안전모', '장갑', '보안경']),
    ('균열·파손', ['균열', '파손', '깨', '손상', '변형']),
]
SEV = {'high': 3, 'medium': 2, 'low': 1, '없음': 0, '': None}


def category(s):
    for name, words in CATEGORIES:
        if any(w in s for w in words):
            return name
    return '기타'


def load_answers():
    answers = {}
    ans = OUT / 'answers.csv'
    if ans.exists():
        for r in csv.reader(ans.open(encoding='utf-8-sig')):
            if r and r[0] != 'file' and len(r) > 2 and (r[1].strip() or r[2].strip()):
                answers[r[0]] = ({category(x.strip()) for x in r[1].split(';') if x.strip()}, r[2].strip())
    return answers


def hz_cat(h):
    return category(h['type'] + ' ' + h.get('description', ''))


# 1백만 토큰당 달러(입력, 출력). Claude 응답의 usage로 비용 어림
PRICE = {'claude-opus-5-5': (4, 20), 'claude-sonnet-5-5': (2, 10), 'claude-haiku-5-5': (0.1, 0.5)}
SEV_NAME = {3: '위험', 2: '주의', 1: '관찰', 0: '없음'}


def evaluate(path, answers):
    """결과 파일 하나 → (사진별 표 줄, 요약 숫자)"""
    lines = [json.loads(l) for l in path.read_text(encoding='utf-8').splitlines() if l.strip()]
    by_file = {}
    for l in lines:
        by_file.setdefault(l['file'], []).append(l)
    rows = ['| 사진 | 성공 | 최고 등급(실행마다) | 등급 일치 | 자주 나온 위험(나온 횟수/실행) |', '|---|---|---|---|---|']
    same_worst = same_any = cat_sev_same = cat_sev_n = n_hz = boxed = n_ok = 0
    jacc, ms = [], []
    tok_in = tok_out = 0
    major_by_file = {}
    human = {'hit': 0, 'total': 0, 'extra': [], 'worst_same': 0, 'worst_n': 0}
    for f, runs in sorted(by_file.items()):
        ok = [r for r in runs if 'error' not in r]
        if not ok:
            rows.append(f'| {f} | 0/{len(runs)} | - | - | - |')
            continue
        n_ok += len(ok)
        ms += [r['ms'] for r in ok if 'ms' in r]
        for r in ok:
            n_hz += len(r['hazards'])
            boxed += sum('box_2d' in h for h in r['hazards'])
            u = r.get('usage') or {}
            tok_in += u.get('input_tokens', 0)
            tok_out += u.get('output_tokens', 0)
        worst = [max((SEV[h['severity']] for h in r['hazards']), default=0) for r in ok]
        cats = [{hz_cat(h) for h in r['hazards']} for r in ok]
        cnt = Counter(c for s in cats for c in s)
        major = {c for c, k in cnt.items() if k * 2 > len(ok)}  # 과반 실행에서 나온 분류
        major_by_file[f] = major
        same_worst += len(set(worst)) == 1
        same_any += len({w > 0 for w in worst}) == 1
        for a in range(len(cats)):
            for b in range(a + 1, len(cats)):
                un = cats[a] | cats[b]
                jacc.append(len(cats[a] & cats[b]) / len(un) if un else 1.0)
        for c, k in cnt.items():  # 같은 분류가 여러 번 나왔을 때 등급이 같은가
            if k < 2:
                continue
            sevs = {max(SEV[h['severity']] for h in r['hazards'] if hz_cat(h) == c)
                    for r in ok if c in {hz_cat(h) for h in r['hazards']}}
            cat_sev_n += 1
            cat_sev_same += len(sevs) == 1
        freq = ', '.join(f'{c} {k}/{len(ok)}' for c, k in cnt.most_common())
        rows.append(f'| {f} | {len(ok)}/{len(runs)} | {" ".join(SEV_NAME[w] for w in worst)} | '
                    f'{"같음" if len(set(worst)) == 1 else "다름"} | {freq or "-"} |')
        if f in answers:
            hc, hw = answers[f]
            human['total'] += len(hc)
            human['hit'] += len(hc & major)
            human['extra'] += [f'{f}: {c}' for c in sorted(major - hc)]
            if SEV.get(hw) is not None:
                human['worst_n'] += 1
                human['worst_same'] += Counter(worst).most_common(1)[0][0] == SEV[hw]
    model = lines[0].get('model', path.stem) if lines else path.stem
    price = next((v for k, v in PRICE.items() if model.startswith(k)), None)
    ms.sort()
    st = {
        'model': model, 'n': len(major_by_file), 'calls_ok': n_ok,
        'errors': Counter(r['error'].split('\n')[0][:60] for r in lines if 'error' in r),
        'same_worst': same_worst, 'same_any': same_any, 'cat_sev': (cat_sev_same, cat_sev_n),
        'jacc': sum(jacc) / len(jacc) if jacc else None,
        'ms_med': ms[len(ms) // 2] if ms else None,
        'hz_per_call': n_hz / max(n_ok, 1), 'boxed': boxed / max(n_hz, 1),
        'cost': (tok_in * price[0] + tok_out * price[1]) / 1e6 if price and (tok_in or tok_out) else None,
        'major': major_by_file, 'human': human,
    }
    return rows, st


def pct(a, b):
    return f'{a}/{b} ({a / b:.0%})' if b else '-'


def ratio(x):
    return '-' if x is None else f'{x:.0%}'


def secs(st):
    return '-' if st['ms_med'] is None else f'{st["ms_med"] / 1000:.1f}초'


def dollars(st):
    return '-' if st['cost'] is None else f'${st["cost"]:.2f}'


def summary_lines(st):
    cs, cn = st['cat_sev']
    errs = '; '.join(f'{e} ×{k}' for e, k in st['errors'].items())
    out = [f'- **최고 등급이 매번 같은 사진**: {pct(st["same_worst"], st["n"])}',
           f'- **위험 있음/없음이 매번 같은 사진**: {pct(st["same_any"], st["n"])}',
           f'- **같은 위험 분류가 다시 나올 때 등급도 같은 비율**: {pct(cs, cn)}',
           f'- **두 실행이 짚은 위험 분류가 겹치는 정도**(평균): {ratio(st["jacc"])}',
           f'- 응답 시간(중앙값): {secs(st)} · 한 번에 위험 {st["hz_per_call"]:.1f}개'
           f' · 위치 박스 있는 위험 {st["boxed"]:.0%}',
           f'- 실패한 호출: {sum(st["errors"].values())}건' + (f' ({errs})' if errs else '')]
    if st['cost'] is not None:
        out.append(f'- 비용 어림: 약 {dollars(st)} (성공 {st["calls_ok"]}번)')
    return out


def human_lines(st):
    h = st['human']
    if not (h['total'] or h['worst_n']):
        return ['사람 정답(answers.csv)이 비어 있어 사람과 비교는 건너뜀.']
    return [f'- **사람이 적은 위험 중 AI가 과반 실행에서 짚은 것**: {pct(h["hit"], h["total"])}',
            f'- **최고 등급이 사람과 같은 사진**: {pct(h["worst_same"], h["worst_n"])}',
            f'- **AI가 더 짚은 것(사람이 놓쳤거나 AI 헛알림 — 사람이 확인)**: {len(h["extra"])}건',
            *[f'  - {e}' for e in h['extra']]]


def report(args):
    path = OUT / args.file
    rows, st = evaluate(path, load_answers())
    out = ['# AI 위험 판단 반복 시험 결과', '',
           f'- 모델: {st["model"]} · 사진 {st["n"]}장 · 성공 {st["calls_ok"]}번',
           '- 위험 종류는 AI가 쓴 문장을 낱말로 대략 묶은 것(예: "바닥 물고임" → 누수·누유)', '',
           *rows, '', '## 요약', '', *summary_lines(st), '', '## 사람 정답과 비교(answers.csv)', '', *human_lines(st)]
    name = 'report.md' if args.file == 'results.jsonl' else f'report_{Path(args.file).stem[8:]}.md'
    (OUT / name).write_text('\n'.join(out) + '\n', encoding='utf-8')
    print('\n'.join(out))


def compare(args):
    """results*.jsonl(모델마다 하나)을 나란히: 일관성·속도·박스·비용 + 모델끼리 짚은 위험 차이"""
    answers = load_answers()
    sts = [evaluate(p, answers)[1] for p in sorted(OUT.glob('results*.jsonl'))]
    sts = [s for s in sts if s['n']]
    out = ['# AI 모델 비교(같은 사진·같은 지시문)', '',
           '| 모델 | 사진 | 성공 | 응답 시간 | 최고 등급 매번 같음 | 같은 분류 등급 같음 | 실행끼리 분류 겹침 | 위험 수/번 | 박스 비율 | 비용 어림 |',
           '|---|---|---|---|---|---|---|---|---|---|']
    for s in sts:
        cs, cn = s['cat_sev']
        out.append(f'| {s["model"]} | {s["n"]} | {s["calls_ok"]} | {secs(s)} | '
                   f'{pct(s["same_worst"], s["n"])} | {pct(cs, cn)} | {ratio(s["jacc"])} | '
                   f'{s["hz_per_call"]:.1f} | {s["boxed"]:.0%} | {dollars(s)} |')
    for i in range(len(sts)):
        for j in range(i + 1, len(sts)):
            a, b = sts[i], sts[j]
            common = sorted(set(a['major']) & set(b['major']))
            if not common:
                continue
            js, diffs = [], []
            for f in common:
                x, y = a['major'][f], b['major'][f]
                js.append(len(x & y) / len(x | y) if x | y else 1.0)
                if x != y:
                    diffs.append(f'  - {f}: {a["model"]}만 {sorted(x - y) or "-"} / {b["model"]}만 {sorted(y - x) or "-"}')
            out += ['', f'## {a["model"]} vs {b["model"]} (공통 사진 {len(common)}장)', '',
                    f'- 과반 실행에서 짚은 위험 분류가 겹치는 정도(평균): {sum(js) / len(js):.0%}',
                    f'- 둘 중 하나만 짚은 것(사람이 다시 볼 대상): {len(diffs)}장', *diffs]
    if any(s['human']['total'] or s['human']['worst_n'] for s in sts):
        for s in sts:
            out += ['', f'## 사람 정답과 비교 — {s["model"]}', '', *human_lines(s)]
    (OUT / 'compare.md').write_text('\n'.join(out) + '\n', encoding='utf-8')
    print('\n'.join(out))


def main():
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')  # 윈도우 콘솔(cp949)에서도 깨지지 않게
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest='cmd', required=True)
    s = sub.add_parser('search')
    s.add_argument('queries', nargs='*')
    s.add_argument('--per', type=int, default=8, help='검색어마다 최대 후보 수')
    f = sub.add_parser('fetch')
    f.add_argument('ids', nargs='+', type=int)
    r = sub.add_parser('report')
    r.add_argument('--file', default='results.jsonl', help='예: results_claude-opus-5-5.jsonl')
    sub.add_parser('compare')
    a = p.parse_args()
    {'search': search, 'fetch': fetch, 'report': report, 'compare': compare}[a.cmd](a)


if __name__ == '__main__':
    main()
