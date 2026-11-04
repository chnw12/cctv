"""손 인식 시뮬레이션: 프레임을 한 번 녹화해 두고, 앱과 같은 모델(hand_landmarker.task)·같은 버전
MediaPipe(0.10.35)로 설정을 바꿔 가며 다시 돌려 비교합니다.

    python tool/hand_sim.py record [--seconds 6] [--camera 0]   # 웹캠 녹화(창에 동작 안내·카운트다운)
    python tool/hand_sim.py run [녹화 폴더]                        # 설정별 인식률·속도 표(기본: 가장 최근 녹화)

실시간이 아니라 녹화본을 돌리므로 에뮬레이터 지연과 상관없이
  ① 모델이 그 크기·밝기에서 손을 잡는지(입력 크기·문턱값)
  ② 처리 속도가 낮으면(에뮬레이터 4FPS vs 폰 15FPS) 추적이 끊겨 얼마나 놓치는지
를 따로 잴 수 있습니다. 필요: pip install mediapipe==0.10.35 (가상환경 권장)
결과: build/hand_sim/<시각>/frames/*.jpg, meta.jsonl, result.json
"""
import argparse
import json
import statistics
import sys
import time
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MODEL = ROOT / 'android' / 'app' / 'src' / 'main' / 'assets' / 'hand_landmarker.task'
OUT = ROOT / 'build' / 'hand_sim'

# 녹화 단계: (이름, 화면 안내(영문 — OpenCV 글꼴에 한글 없음), 한국어 설명)
PHASES = [
    ('palm', 'OPEN PALM to camera', '손바닥을 카메라 쪽으로 펴기'),
    ('point', 'POINT with index finger, move slowly', '검지로 가리키며 천천히 움직이기'),
    ('fist', 'FIST', '주먹'),
    ('none', 'NO HAND (hands down)', '손 내리기(손 없음)'),
]


def record(seconds_per_phase, camera):
    import cv2
    cap = cv2.VideoCapture(camera, cv2.CAP_DSHOW)
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, 1280)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 720)
    if not cap.isOpened():
        sys.exit('웹캠을 열 수 없습니다(에뮬레이터가 카메라를 쓰고 있으면 카메라 화면을 닫으세요)')
    out = OUT / datetime.now().strftime('%Y%m%d-%H%M%S')
    (out / 'frames').mkdir(parents=True)
    meta = open(out / 'meta.jsonl', 'w', encoding='utf-8')
    win = 'hand_sim record'
    cv2.namedWindow(win, cv2.WINDOW_NORMAL)
    cv2.setWindowProperty(win, cv2.WND_PROP_TOPMOST, 1)

    def show(frame, lines, color):
        view = cv2.flip(frame, 1)  # 미리보기만 거울처럼(저장은 카메라가 본 그대로)
        for k, text in enumerate(lines):
            cv2.putText(view, text, (30, 60 + 50 * k), cv2.FONT_HERSHEY_SIMPLEX, 1.4, (0, 0, 0), 6)
            cv2.putText(view, text, (30, 60 + 50 * k), cv2.FONT_HERSHEY_SIMPLEX, 1.4, color, 2)
        cv2.imshow(win, view)
        return cv2.waitKey(1) & 0xFF

    print('창이 뜨면 안내대로 손을 움직이세요(q = 중단)')
    for phase, hint, ko in PHASES:
        print(f'  {ko} — {seconds_per_phase}초')
    t0 = time.time()
    while time.time() - t0 < 5:  # 카운트다운
        ok, f = cap.read()
        if ok and show(f, [f'START IN {5 - int(time.time() - t0)}', PHASES[0][1]], (0, 255, 255)) == ord('q'):
            return
    i, start, last = 0, time.time(), 0.0
    for phase, hint, _ in PHASES:
        end = time.time() + seconds_per_phase
        while (left := end - time.time()) > 0:
            ok, f = cap.read()
            if not ok:
                continue
            now = time.time()
            if now - last >= 1 / 15:  # 15FPS로 저장(폰 카메라 설정과 같음)
                last = now
                cv2.imwrite(str(out / 'frames' / f'{i:05d}.jpg'), f, [cv2.IMWRITE_JPEG_QUALITY, 92])
                meta.write(json.dumps({'i': i, 't': round((now - start) * 1000), 'phase': phase}) + '\n')
                i += 1
            if show(f, [f'REC  {hint}', f'{left:4.1f}s'], (0, 0, 255)) == ord('q'):
                break
    meta.close()
    cap.release()
    cv2.destroyAllWindows()
    print(f'녹화 {i}장: {out}')


def portrait(frame, width):
    """앱 화면처럼 세로 9:16로 가운데를 잘라 width 폭으로(에뮬레이터가 웹캠을 세로 카메라로 줄 때와 같은 모양)"""
    import cv2
    h, w = frame.shape[:2]
    cw = int(h * 9 / 16)
    x0 = (w - cw) // 2
    crop = frame[:, x0:x0 + cw]
    return cv2.resize(crop, (width, int(width * 16 / 9)), interpolation=cv2.INTER_AREA)


def run(folder):
    import cv2
    import mediapipe as mp
    from mediapipe.tasks import python as mpt
    from mediapipe.tasks.python import vision

    meta = [json.loads(l) for l in open(folder / 'meta.jsonl', encoding='utf-8')]
    raw = [cv2.imread(str(folder / 'frames' / f"{m['i']:05d}.jpg")) for m in meta]

    def landmarker(conf, video):
        return vision.HandLandmarker.create_from_options(vision.HandLandmarkerOptions(
            base_options=mpt.BaseOptions(model_asset_path=str(MODEL)),
            running_mode=vision.RunningMode.VIDEO if video else vision.RunningMode.IMAGE,
            num_hands=2, min_hand_detection_confidence=conf,
            min_hand_presence_confidence=conf, min_tracking_confidence=conf))

    def evaluate(width, conf, fps, video=True):
        lm = landmarker(conf, video)
        found, ms, used, last_t = {}, [], [], -1e9
        for m, f in zip(meta, raw):
            if m['t'] - last_t < 1000 / fps:  # 처리 속도 흉내: 그 사이 프레임은 못 봄
                continue
            last_t = m['t']
            img = cv2.cvtColor(portrait(f, width), cv2.COLOR_BGR2RGB)
            t = time.perf_counter()
            r = lm.detect_for_video(mp.Image(image_format=mp.ImageFormat.SRGB, data=img), m['t']) \
                if video else lm.detect(mp.Image(image_format=mp.ImageFormat.SRGB, data=img))
            ms.append((time.perf_counter() - t) * 1000)
            found[m['i']] = len(r.hand_landmarks) > 0
            used.append(m['i'])
        lm.close()
        return found, used, ms

    # 기준(정답 대용): 가장 좋은 조건(720px, 문턱 0.3)에서 추적 모드나 매 장 새로 찾기 중 하나라도 잡으면 "손 있음"
    print('기준 만드는 중…')
    ref_v, _, _ = evaluate(720, 0.3, 30)
    ref_i, _, _ = evaluate(720, 0.3, 30, video=False)
    ref = {i: ref_v.get(i, False) or ref_i.get(i, False) for i in ref_v}

    settings = [
        ('지금 앱(240px·0.5·15FPS)', 240, 0.5, 15),
        ('240px·0.5·4FPS(에뮬레이터 속도)', 240, 0.5, 4),
        ('240px·0.3·15FPS', 240, 0.3, 15),
        ('360px·0.5·15FPS', 360, 0.5, 15),
        ('360px·0.3·15FPS', 360, 0.3, 15),
        ('360px·0.3·4FPS', 360, 0.3, 4),
        ('720px·0.3·15FPS', 720, 0.3, 15),
    ]
    phase_of = {m['i']: m['phase'] for m in meta}
    phases = [p for p, _, _ in PHASES]
    rows = []
    for name, width, conf, fps in settings:
        found, used, ms = evaluate(width, conf, fps)
        row = {'설정': name, 'width': width, 'conf': conf, 'fps': fps,
               'ms_med': round(statistics.median(ms), 1), 'ms_p90': round(sorted(ms)[int(len(ms) * 0.9)], 1)}
        for p in phases:
            idx = [i for i in used if phase_of[i] == p]
            if p == 'none':  # 손 없음: 잡으면 오탐
                row[p] = sum(found[i] for i in idx) / len(idx) if idx else None
            else:  # 기준이 손을 잡은 프레임 중 이 설정도 잡은 비율(재현율)
                pos = [i for i in idx if ref.get(i)]
                row[p] = sum(found[i] for i in pos) / len(pos) if pos else None
        rows.append(row)

    ref_rate = {p: (lambda idx: sum(ref[i] for i in idx) / len(idx) if idx else None)(
        [i for i in ref if phase_of[i] == p]) for p in phases}
    pct = lambda v: '   -' if v is None else f'{v * 100:3.0f}%'
    print(f"\n녹화 {len(meta)}장 · 기준이 손을 잡은 비율: " +
          ', '.join(f'{ko} {pct(ref_rate[p])}' for p, _, ko in PHASES))
    print('\n설정                              손바닥  가리키기  주먹  손없음(오탐)  인식 시간(PC 중앙/90%)')
    for r in rows:
        print(f"{r['설정']:<32} {pct(r['palm']):>6} {pct(r['point']):>8} {pct(r['fist']):>5}"
              f" {pct(r['none']):>10}     {r['ms_med']}/{r['ms_p90']}ms")
    (folder / 'result.json').write_text(json.dumps({'ref': ref_rate, 'rows': rows}, ensure_ascii=False, indent=1),
                                       encoding='utf-8')
    print(f'\n저장: {folder / "result.json"}')


def main():
    for s in (sys.stdout, sys.stderr):
        s.reconfigure(encoding='utf-8', errors='replace')
    ap = argparse.ArgumentParser(description='손 인식 시뮬레이션')
    sub = ap.add_subparsers(dest='cmd', required=True)
    r = sub.add_parser('record')
    r.add_argument('--seconds', type=float, default=6, help='동작 하나당 초(4가지)')
    r.add_argument('--camera', type=int, default=0)
    u = sub.add_parser('run')
    u.add_argument('folder', nargs='?')
    a = ap.parse_args()
    if a.cmd == 'record':
        record(a.seconds, a.camera)
    else:
        folder = Path(a.folder) if a.folder else max(OUT.iterdir(), key=lambda p: p.name)
        run(folder)


if __name__ == '__main__':
    main()
