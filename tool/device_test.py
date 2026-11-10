"""실기기 테스트 도우미: 설치 → 화면 안내대로 폰 조작 → 로그 수집 → 요약.

    python tool/device_test.py run              # 연결된 실기기로 안내 테스트(약 10분)
    python tool/device_test.py run --soak 30    # 끝나고 30분 배터리·발열 측정 추가
    python tool/device_test.py summary <로그>   # 저장된 로그 다시 요약

대화로 안내할 때(터미널 입력 없이): 기록만 켜 두고 단계 표시는 폰 로그에 남김
    python tool/device_test.py record           # 기록 시작(백그라운드로), "mark end"가 오면 요약하고 끝
    python tool/device_test.py mark phase still # 단계 시작 표시 / mark answer pan | 질문 | y / mark end

결과는 build/device_logs/<시각>.log(원본), <시각>_summary.txt(요약)에 남습니다.
앱의 PERF 로그(5초마다 FPS·추론·자이로·노출, AI 때 촬영·응답 시간)를 모아 단계별로 판정합니다.
"""
import argparse
import os
import re
import shutil
import statistics
import subprocess
import sys
import threading
import time
from datetime import datetime
from pathlib import Path

PKG = 'com.example.facility_camera'
ROOT = Path(__file__).resolve().parent.parent
APK_DIR = ROOT / 'build' / 'app' / 'outputs' / 'flutter-apk'
LOG_DIR = ROOT / 'build' / 'device_logs'
ADB = None

# (이름, 할 일, 시간(초, None이면 Enter 기다림), 끝나고 물어볼 것 — 전부 "예"가 정상)
PHASES = [
    ('setup', '앱이 열렸습니다. 카메라 권한을 허용하고 홈 → "새 점검 시작"(장소는 아무거나) → 카메라 화면까지 들어가세요.',
     None, []),
    ('still', '폰을 설비(배관·분전반·밸브 등)에 향하고 가만히 들고 있으세요.', 45, []),
    ('pan', '천천히 좌우로 돌리세요(한 번에 2~3초, 설비 여러 개가 화면을 지나가게). 위아래도 조금.', 60,
     ['같은 물체의 박스 번호(#)가 대체로 그대로 유지됐나요?']),
    ('ai', '볼륨 키(또는 노란 AI 점검 버튼)로 AI 점검을 3번 하세요. 매번 다른 설비를 향하고, 결과가 나오면 다음으로.',
     None, ['AI 설명이 대체로 맞았나요?', '위험 박스 위치가 실제 위치와 맞았나요?']),
    ('anchor', 'AI 결과(위험 박스)가 떠 있는 채로 폰을 좌우로 천천히 크게 돌려 보세요.', 30,
     ['위험 박스가 실제 위치에 붙어서 따라갔나요?', '화면 밖으로 나갔을 때 가장자리 화살표가 맞는 방향을 가리켰나요?']),
    ('dark', '어두운 곳(불 꺼진 구석, 기계 뒤쪽)을 20초 비춘 뒤 밝은 곳으로 돌아오세요.', 40,
     ['어두운 곳에서 화면이 조금 밝아졌나요?', '밝기가 깜빡이듯 오르내리지 않았나요?']),
    ('controls', '손전등 버튼, 두 손가락 확대(줌), 화면 탭(초점)을 해 보세요.', None,
     ['손전등이 켜지고 꺼졌나요?', '줌이 됐나요?', '탭한 곳에 초점이 맞았나요?']),
    ('save', '"기록 저장"과 "사진만 기록"을 한 번씩 하고, 점검을 종료한 뒤 점검 상세 화면을 확인하세요.', None,
     ['기록이 사진과 함께 남았나요?']),
]

# 앱 로그 + 강제 종료(E AndroidRuntime, 네이티브는 F DEBUG) + 단계 표시(FCTEST).
# 그냥 AndroidRuntime은 adb 명령이 남기는 잡음
KEEP = re.compile(r' flutter | E AndroidRuntime| F DEBUG |FATAL| FCTEST ')

# `mark`가 폰 로그에 남긴 단계 표시. logcat 순서 그대로 앱 로그 사이에 끼므로 따로 맞출 필요 없음
MARK = re.compile(r' FCTEST\s*: (.*)$')


def find_adb():
    exe = 'adb.exe' if os.name == 'nt' else 'adb'
    for base in (os.environ.get('ANDROID_HOME'), os.environ.get('ANDROID_SDK_ROOT'),
                 os.path.join(os.environ.get('LOCALAPPDATA', ''), 'Android', 'Sdk')):
        if base and (Path(base) / 'platform-tools' / exe).exists():
            return str(Path(base) / 'platform-tools' / exe)
    return shutil.which('adb')


def adb(serial, *args):
    r = subprocess.run([ADB, '-s', serial, *args], capture_output=True, text=True,
                       encoding='utf-8', errors='replace')
    return (r.stdout + r.stderr).strip()


def pick_device(serial):
    out = subprocess.run([ADB, 'devices'], capture_output=True, text=True).stdout
    rows = [l.split('\t') for l in out.splitlines()[1:] if '\t' in l]
    if serial:
        if [serial, 'device'] in rows:
            return serial
        sys.exit(f'{serial} 기기가 연결돼 있지 않습니다. 지금 목록: {rows}')
    if any(st == 'unauthorized' for _, st in rows):
        sys.exit('폰 화면에 "USB 디버깅을 허용하시겠습니까?"가 떠 있습니다. "허용"을 누르고 다시 실행하세요.')
    phones = [s for s, st in rows if st == 'device' and not s.startswith('emulator-')]
    if not phones:
        sys.exit('연결된 폰이 없습니다. DEVICE_TEST.md의 "준비"를 따라 USB 디버깅을 켜고 연결하세요.\n'
                 '(에뮬레이터로 도구만 확인하려면 --serial emulator-5554)')
    if len(phones) > 1:
        print(f'폰이 여러 대라 첫 번째({phones[0]})를 씁니다. 바꾸려면 --serial')
    return phones[0]


def device_info(serial):
    get = lambda k: adb(serial, 'shell', 'getprop', k)
    return {
        'model': f"{get('ro.product.manufacturer')} {get('ro.product.model')}",
        'android': f"{get('ro.build.version.release')} (SDK {get('ro.build.version.sdk')})",
        'abi': get('ro.product.cpu.abilist'),
    }


def install(serial, abis, reinstall):
    # 기기가 내세우는 순서대로(첫 번째가 기본 ABI). x86 에뮬레이터의 ARM 번역은 느려서 뒤로
    abi = next((a for a in abis.split(',') if (APK_DIR / f'app-{a}-release.apk').exists()), None)
    apk = APK_DIR / f'app-{abi}-release.apk'
    if not abi:
        sys.exit(f'{apk.name}이 없습니다. 먼저 빌드하세요:\n'
                 '  flutter build apk --release --split-per-abi --dart-define-from-file=secrets.json --dart-define-from-file=.env')
    if reinstall:
        print('기존 앱 삭제(점검 기록도 지워짐)…')
        adb(serial, 'uninstall', PKG)
    print(f'설치 중: {apk.name} …')
    out = adb(serial, 'install', '-r', str(apk))
    if 'Success' not in out:
        hint = ('\n이미 깔린 앱과 서명·버전이 달라서입니다. 지우고 새로 깔려면 --reinstall (폰의 점검 기록 삭제)'
                if 'UPDATE_INCOMPATIBLE' in out or 'DOWNGRADE' in out else '')
        sys.exit(f'설치 실패: {out}{hint}')
    return apk.name


def battery(serial):
    out = adb(serial, 'shell', 'dumpsys', 'battery')
    # 줄 처음에서만: 삼성은 "Capacity level: -1"·충전 기록 줄이 더 붙음(Z Flip7에서 확인)
    num = lambda k: int(m.group(1)) if (m := re.search(rf'^\s*{k}: (-?\d+)', out, re.M)) else None
    charging = bool(re.search(r'(AC|USB|Wireless) powered: true', out))
    temp = num('temperature')
    return {'level': num('level'), 'temp': temp / 10 if temp is not None else None, 'charging': charging}


def meminfo_pss(serial):
    out = adb(serial, 'shell', 'dumpsys', 'meminfo', PKG)
    m = re.search(r'TOTAL PSS:\s+(\d+)', out) or re.search(r'^\s*TOTAL\s+(\d+)', out, re.M)
    return int(m.group(1)) if m else None


class Recorder:
    """logcat을 계속 읽어 앱 관련 줄만 파일에. 단계 표시(# …)도 같은 파일에 순서대로."""

    def __init__(self, serial, path):
        self.serial, self.lock = serial, threading.Lock()
        self.ended = threading.Event()  # "mark end"를 받음
        self.f = open(path, 'a', encoding='utf-8')
        subprocess.run([ADB, '-s', serial, 'logcat', '-c'])
        self.start()

    def start(self):
        self.p = subprocess.Popen([ADB, '-s', self.serial, 'logcat', '-v', 'threadtime'],
                                  stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                  text=True, encoding='utf-8', errors='replace')
        threading.Thread(target=self._run, daemon=True).start()

    def _run(self):
        for line in self.p.stdout:
            if KEEP.search(line) or (PKG in line and 'died' in line):
                self.write(line.rstrip('\n'))
            if (m := MARK.search(line.rstrip())) and m.group(1).strip() == 'end':
                self.ended.set()

    def write(self, line):
        with self.lock:
            if not self.f.closed:
                self.f.write(line + '\n')
                self.f.flush()

    def mark(self, kind, text):
        self.write(f'# {kind} {text}')

    def stop(self):
        self.p.terminate()
        time.sleep(0.5)
        with self.lock:
            self.f.close()


def ask(rec, phase, questions, auto):
    for q in questions:
        a = 's' if auto else ''
        while a not in ('y', 'n', 's'):
            a = input(f'  {q} [y=예 / n=아니오 / s=건너뜀] ').strip().lower()[:1]
        rec.mark('answer', f'{phase} | {q} | {a}')
        if a == 'n':
            note = '' if auto else input('    어땠는지 한 줄(그냥 Enter 가능): ').strip()
            if note:
                rec.mark('note', f'{phase} | {note}')


def run_phases(rec, auto):
    for i, (name, todo, secs, questions) in enumerate(PHASES, 1):
        print(f'\n[{i}/{len(PHASES)}] {todo}')
        rec.mark('phase', name if secs is None else f'{name}:ready')
        if secs is None:
            if auto:
                time.sleep(5)
            else:
                input('  다 했으면 Enter ')
        else:
            if not auto:
                input('  준비되면 Enter (시작하면 시간을 잽니다) ')
            rec.mark('phase', name)  # 시간 재는 구간의 실제 시작
            total = 10 if auto else secs
            for left in range(total, 0, -5):
                print(f'  … {left}초 남음', end='\r', flush=True)
                time.sleep(min(5, left))
            print('  끝!            ')
            rec.mark('phase', f'{name}:done')
        ask(rec, name, questions, auto)


def soak(rec, serial, minutes, auto):
    b0 = battery(serial)
    rec.mark('battery', f"start level={b0['level']} temp={b0['temp']} charging={b0['charging']}")
    print(f'\n[배터리·발열 {minutes}분] 설정 → "안 쓰면 카메라 멈춤"을 "안 멈춤"으로 바꾸고, '
          '점검 카메라 화면을 켠 채 폰을 설비 쪽으로 세워 두세요.')
    rec.mark('phase', 'soak')
    if b0['charging'] and not auto:
        # USB로 연결돼 있으면 충전 중이라 소모량을 못 잼 → 뽑고 재고, 다시 꽂으면 버퍼에 남은 로그를 가져옴
        since = adb(serial, 'shell', "date '+%m-%d %H:%M:%S'")  # 한 문자열로(공백에서 갈라지지 않게)
        input('  충전 중이면 소모량을 잴 수 없습니다. 준비되면 Enter 를 누르고 바로 USB 케이블을 뽑으세요. ')
        rec.stop()
        end = time.time() + minutes * 60
        while (left := end - time.time()) > 0:
            print(f'  … {int(left // 60)}분 {int(left % 60)}초 남음 (폰은 그대로)', end='\r', flush=True)
            time.sleep(min(10, left))
        input('\n  시간 됐습니다. 케이블을 다시 꽂고(USB 디버깅 허용) Enter ')
        subprocess.run([ADB, '-s', serial, 'wait-for-device'])
        rec.f = open(rec.f.name, 'a', encoding='utf-8')
        dump = adb(serial, 'logcat', '-d', '-v', 'threadtime').splitlines()
        for line in dump:
            if line[:14] >= since and (KEEP.search(line) or (PKG in line and 'died' in line)):
                rec.write(line)
        subprocess.run([ADB, '-s', serial, 'logcat', '-c'])  # 가져온 건 비우고 이어서(중복 방지)
        rec.start()
    else:
        end = time.time() + (20 if auto else minutes * 60)
        while (left := end - time.time()) > 0:
            print(f'  … {int(left // 60)}분 {int(left % 60)}초 남음', end='\r', flush=True)
            time.sleep(min(10, left))
        print()
    b1 = battery(serial)
    rec.mark('battery', f"end level={b1['level']} temp={b1['temp']} charging={b1['charging']} minutes={minutes}")


# ── 요약 ──────────────────────────────────────────────

def parse_perf(line):
    i = line.find('PERF ')
    if i < 0:
        return None
    toks = line[i + 5:].split()
    d = {'kind': toks[0] if toks and '=' not in toks[0] else 'source'}
    for t in toks:
        if '=' in t:
            k, v = t.split('=', 1)
            d[k] = v
        else:
            d[t] = True
    return d


def num(v, cast=float):
    m = re.match(r'-?\d+(\.\d+)?', str(v))
    return cast(m.group(0)) if m else None


def pair(v):
    a, b = re.findall(r'-?\d+\.?\d*', v)[:2]
    return float(a), float(b)


def med(xs):
    return statistics.median(xs) if xs else None


def p90(xs):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(len(xs) * 0.9))] if xs else None


def fmt(x, unit=''):
    if x is None:
        return '-'
    return f'{x:.0f}{unit}' if isinstance(x, (int, float)) and abs(x) >= 10 else f'{x:g}{unit}'


def summarize(lines):
    phase, info = 'setup', {}
    seg = {}  # 단계 → PERF 목록
    answers, notes, errors, batt = [], [], [], []
    for line in lines:
        line = line.rstrip('\n')
        if m := MARK.search(line):
            line = '# ' + m.group(1)
        if line.startswith('# '):
            kind, _, rest = line[2:].partition(' ')
            if kind == 'phase':
                phase = rest
                seg.setdefault(phase, [])
            elif kind == 'device':
                k, _, v = rest.partition('=')
                info[k] = v
            elif kind == 'answer':
                answers.append(rest.split(' | '))
            elif kind == 'note':
                notes.append(rest)
            elif kind == 'battery':
                label, *kv = rest.split()
                batt.append({'_': label, **dict(t.split('=', 1) for t in kv)})
            elif kind == 'meminfo':
                info['pss'] = rest
            continue
        p = parse_perf(line)
        if p:
            seg.setdefault(phase, []).append(p)
        elif (' E flutter' in line or ' E AndroidRuntime' in line or 'FATAL' in line
              or ' F DEBUG ' in line or 'died' in line or 'detect error' in line):
            errors.append(line)

    out = []
    w = out.append
    w('실기기 테스트 요약')
    for k in ('model', 'android', 'abi', 'apk', 'started'):
        if k in info:
            w(f'  {k}: {info[k]}')
    allp = [p for ps in seg.values() for p in ps]
    src = [p for p in allp if p['kind'] == 'source' and p.get('source') == 'camera']
    if src:
        s0 = src[0]
        w(f"  카메라: {s0.get('preset')} · {s0.get('frame')} · 카메라 FPS 상한 {s0.get('camFps')}"
          f" · 줌 {s0.get('zoom', '-')} · 노출 최대 {s0.get('ev', '-/-').split('/')[-1]}EV")
    checks = []

    def judge(ok, text):
        checks.append(('OK ' if ok else '확인') + '  ' + text)

    # 처리 성능: 절전(eco) 아닌 줄만
    full = [p for p in src if not p.get('eco')]
    procs = [num(p['proc'], int) for p in full if 'proc' in p][1:]  # 첫 줄은 워밍업
    infers = [num(p['infer'], int) for p in full if 'infer' in p][1:]
    ins = [num(p['in'], int) for p in full if 'in' in p][1:]
    if procs:
        cap = num(src[0].get('camFps'), int) or 30
        w(f'\n처리 성능(절전 아닐 때): 처리 FPS 중앙 {fmt(med(procs))} (최소 {min(procs)}, 최대 {max(procs)}), '
          f'입력 {fmt(med(ins))}, 추론 중앙 {fmt(med(infers), "ms")} / 90% {fmt(p90(infers), "ms")}')
        judge(med(procs) >= cap * 0.6, f'처리 FPS {fmt(med(procs))} (카메라 {cap}FPS의 60% 이상이면 좋음, 에뮬레이터는 6~7)')
        judge(p90(infers) <= 120, f'추론 90% {fmt(p90(infers), "ms")} (120ms 이하면 좋음)')

    still = [p for p in seg.get('still', []) if p['kind'] == 'source']
    if len(still) >= 3:
        eco = sum(1 for p in still if p.get('eco')) / len(still)
        w(f'\n가만히(still): 절전 비율 {eco:.0%}')
        if 'bias' in still[-1]:
            judge(eco >= 0.5, f'가만히 들고 있을 때 절전(eco) {eco:.0%} (손떨림이 0.05rad/s를 자주 넘으면 낮게 나옴)')

    gy = [p for p in src if 'gyro' in p]
    if gy:
        rates = [max(abs(a) for a in pair(p['gyro'])) for p in gy]
        fovs = [num(p['fovX'], int) for p in gy]
        fov0, fov1 = fovs[0], fovs[-1]
        lens = num(gy[-1].get('lensX'), int)  # 렌즈 값(초점거리·센서 크기)으로 계산한 화각
        bx, by = pair(gy[-1]['bias'])
        w(f'\n자이로: 최대 {max(rates):.2f}rad/s, 화각(가로) {fov0}° → {fov1}° (범위 {min(fovs)}~{max(fovs)}°'
          f"{f', 렌즈 값 {lens}°' if lens else ''}), 영점 {bx:+.4f},{by:+.4f}rad/s")
        if lens:
            judge(abs(fov1 - lens) <= lens * 0.15, f'학습된 가로 화각 {fov1}° (렌즈 값 {lens}°의 ±15% 안이면 좋음)')
        else:
            judge(35 <= fov1 <= 80, f'학습된 가로 화각 {fov1}° (보통 폰 세로 화면 40~60°)')
        judge(max(abs(bx), abs(by)) < 0.015, f'자이로 영점 {max(abs(bx), abs(by)):.4f}rad/s (0.015 미만이면 정상)')
    else:
        w('\n자이로: 로그 없음(설정에서 자이로 보정이 꺼져 있거나 센서 없음)')

    pan = [p for p in seg.get('pan', []) if p['kind'] == 'source' and 'ids' in p]
    if len(pan) >= 2:
        new_ids = num(pan[-1]['ids'], int) - num(pan[0]['ids'], int)
        objs = med([num(p['objs'], int) for p in pan])
        w(f'돌리기(pan): 새로 생긴 ID {new_ids}개, 화면 속 물체 중앙 {fmt(objs)}개 '
          '(지나간 설비 수보다 훨씬 많으면 ID가 끊기는 것)')

    idl = [num(p['ids'], int) for p in src if 'ids' in p]
    if len(idl) >= 3:
        # 카메라를 다시 열면 0부터 다시 셈 → 줄어든 곳은 새로 센 만큼만 더함
        grown = sum(b - a if b >= a else b for a, b in zip(idl, idl[1:]))
        mins = (len(idl) - 1) * 5 / 60  # PERF는 처리 중 5초마다
        objs = med([num(p['objs'], int) for p in src if 'objs' in p])
        w(f'ID: 새로 생긴 ID {grown}개(약 {grown / mins:.0f}개/분), 화면 속 물체 중앙 {fmt(objs)}개 '
          '(가만히 있을 때도 계속 늘면 같은 물체 ID가 끊기는 것)')

    snaps = [p for p in allp if p['kind'] == 'snapshot']
    if snaps:
        cap_ms = [num(p['capture'], int) for p in snaps]
        ai_ms = [num(p['ai'], int) for p in snaps if 'ai' in p]
        steady = [num(p['steady'], int) for p in snaps]
        w(f'\nAI 점검 {len(snaps)}회: 흔들림 대기 중앙 {fmt(med(steady), "ms")}, 촬영 중앙 {fmt(med(cap_ms), "ms")}, '
          f'AI 응답 중앙 {fmt(med(ai_ms), "ms")} (최대 {fmt(max(ai_ms) if ai_ms else None, "ms")}), '
          f"사진 {snaps[0].get('size')} {snaps[0].get('kb')}KB")
        judge(med(cap_ms) <= 1000, f'촬영 {fmt(med(cap_ms), "ms")} (1초 이하면 좋음)')
        if ai_ms:
            judge(med(ai_ms) <= 5000, f'AI 응답 {fmt(med(ai_ms), "ms")} (5초 이하면 좋음, 에뮬레이터 2~3초)')

    exp = [p for p in allp if p['kind'] == 'exposure']
    dark_src = [p for p in seg.get('dark', []) if p['kind'] == 'source']
    if exp or dark_src:
        # 어두운 곳 단계 없이 자유롭게 썼으면 전체에서 봄(Z Flip7 첫 테스트에서 ev=1.0인데 "없음"으로 나왔음)
        pool = dark_src or src
        where = '어두운 곳 단계에서' if dark_src else '전체에서'
        went_dark = any(p.get('dark') == 'true' for p in pool) or any(p.get('dark') == 'true' for p in exp)
        boosted = any(num(p.get('ev', '0'), float) for p in pool)
        w(f'\n어두움·노출: 어둡다 ↔ 밝다 전환 {len(exp)}번, {where} 어두움 판정 '
          f"{'있음' if went_dark else '없음'}, 노출 올림 {'있음' if boosted else '없음'}")
        for p in exp[:8]:
            w(f"  전환: dark={p.get('dark')} 밝기={p.get('luma')} 환산={p.get('base')} 그때 노출={p.get('ev')}")
        judge(len(exp) <= 6, f'밝기 전환 {len(exp)}번 (어두운 곳 한 번 다녀오면 2번이 정상, 많으면 깜빡임)')

    if batt and len(batt) >= 2:
        # 소모량은 측정 구간(start → end), 없으면 처음 → 끝
        b0 = next((b for b in reversed(batt) if b['_'] == 'start'), batt[0])
        b1 = batt[-1]
        mins = num(b1.get('minutes'), float) or 0
        drop = (num(b0['level'], int) or 0) - (num(b1['level'], int) or 0)
        rate = drop / mins * 60 if mins else None
        if mins:
            w(f"\n배터리: {b0['level']}% → {b1['level']}% ({fmt(mins)}분, 시간당 {fmt(rate, '%')}), "
              f"온도 {b0['temp']}° → {b1['temp']}°C, 충전 중이었나: {b1.get('charging')}")
        else:
            w(f"\n온도: {b0['temp']}° → {b1['temp']}°C (배터리 소모량은 --soak 로 측정)")
        if rate is not None and b1.get('charging') == 'False':
            judge(rate <= 25, f'배터리 시간당 {fmt(rate, "%")} (25% 이하면 반나절 점검 가능)')
        if b1.get('temp') not in (None, 'None'):
            judge(float(b1['temp']) <= 42, f"온도 {b1['temp']}°C (42°C 이하면 좋음)")
    if 'pss' in info:
        pss = num(info['pss'], int)
        w(f'\n메모리(PSS): {pss // 1024 if pss else "-"}MB')
        if pss:
            judge(pss < 400 * 1024, f'메모리 {pss // 1024}MB (400MB 미만이면 좋음, 에뮬레이터 150~290MB)')

    judge(not errors, f'앱 오류·강제 종료 {len(errors)}건')
    if answers:
        w('\n직접 확인한 것:')
        for ph, q, a in answers:
            w(f"  [{ {'y': '예', 'n': '아니오', 's': '건너뜀'}.get(a, a)}] ({ph}) {q}")
        for n in notes:
            w(f'  메모: {n}')
        bad = [q for _, q, a in answers if a == 'n']
        judge(not bad, f'직접 확인 "아니오" {len(bad)}건')
    if errors:
        w('\n오류 줄(앞 10개):')
        out.extend('  ' + e for e in errors[:10])

    w('\n판정:')
    out.extend('  ' + c for c in checks)
    return '\n'.join(out)


def main():
    global ADB
    for s in (sys.stdout, sys.stderr):
        s.reconfigure(encoding='utf-8', errors='replace')
    ap = argparse.ArgumentParser(description='실기기 테스트 도우미')
    sub = ap.add_subparsers(dest='cmd', required=True)
    r = sub.add_parser('run', help='설치 → 안내 테스트 → 요약')
    r.add_argument('--serial', help='기기 지정(adb devices의 이름)')
    r.add_argument('--soak', type=int, default=0, help='배터리·발열 측정 분(0이면 안 함)')
    r.add_argument('--no-install', action='store_true', help='설치 건너뛰기(이미 깔린 앱 그대로)')
    r.add_argument('--reinstall', action='store_true', help='지우고 새로 설치(폰의 점검 기록 삭제)')
    r.add_argument('--auto', action='store_true', help='질문 없이 짧게(도구 자체 확인용)')
    s = sub.add_parser('summary', help='저장된 로그 요약')
    s.add_argument('log')
    rc = sub.add_parser('record', help='기록만(단계는 mark로), "mark end"가 오면 요약하고 끝')
    rc.add_argument('--serial', help='기기 지정(adb devices의 이름)')
    mk = sub.add_parser('mark', help='폰 로그에 단계 표시 남기기(record와 같이)')
    mk.add_argument('--serial', help='기기 지정(adb devices의 이름)')
    mk.add_argument('text', nargs='+', help='예: phase still / answer pan | 질문 | y / end')
    a = ap.parse_args()

    if a.cmd == 'summary':
        print(summarize(Path(a.log).read_text(encoding='utf-8').splitlines()))
        return

    ADB = find_adb()
    if not ADB:
        sys.exit('adb를 못 찾았습니다. Android SDK platform-tools 설치 또는 ANDROID_HOME 설정이 필요합니다.')
    serial = pick_device(a.serial)
    if a.cmd == 'mark':
        # 기기 셸이 |·공백을 해석하지 않게 작은따옴표로 감쌈
        text = ' '.join(a.text).replace("'", "'\\''")
        adb(serial, 'shell', f"log -t FCTEST '{text}'")
        return
    info = device_info(serial)
    print(f"기기: {info['model']} · Android {info['android']} · {info['abi']}")
    apk = ('(설치 안 함)' if a.cmd == 'record' or a.no_install
           else install(serial, info['abi'], a.reinstall))

    LOG_DIR.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime('%Y%m%d-%H%M%S')
    log = LOG_DIR / f'{stamp}.log'
    rec = Recorder(serial, log)
    for k, v in {**info, 'apk': apk, 'started': stamp, 'serial': serial}.items():
        rec.mark('device', f'{k}={v}')
    b = battery(serial)
    rec.mark('battery', f"begin level={b['level']} temp={b['temp']} charging={b['charging']}")
    adb(serial, 'shell', 'monkey', '-p', PKG, '-c', 'android.intent.category.LAUNCHER', '1')
    print(f'로그 기록 중: {log.relative_to(ROOT)}  (중간에 그만두려면 Ctrl+C — 그때까지의 요약은 남음)')

    try:
        if a.cmd == 'record':
            print('단계 표시는 "python tool/device_test.py mark phase <이름>", 끝내려면 "… mark end"')
            while not rec.ended.wait(1):
                pass
        else:
            run_phases(rec, a.auto)
            if a.soak:
                soak(rec, serial, a.soak, a.auto)
    except KeyboardInterrupt:
        print('\n중단 — 여기까지 요약합니다.')
        rec.mark('phase', 'interrupted')
    pss = meminfo_pss(serial)
    if pss:
        rec.mark('meminfo', str(pss))
    if not getattr(a, 'soak', 0):
        b = battery(serial)
        rec.mark('battery', f"end level={b['level']} temp={b['temp']} charging={b['charging']} minutes=0")
    rec.stop()

    text = summarize(log.read_text(encoding='utf-8').splitlines())
    summary = log.with_name(f'{stamp}_summary.txt')
    summary.write_text(text, encoding='utf-8')
    print('\n' + text)
    print(f'\n저장: {log.relative_to(ROOT)} / {summary.relative_to(ROOT)}')


if __name__ == '__main__':
    main()
