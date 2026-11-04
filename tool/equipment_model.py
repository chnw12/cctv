"""설비 전용 탐지기(시험) 만들기: YOLOE에 설비 이름 10종을 넣어 고정 → 폰용 ONNX로 내보내기.

학습 없이 이름(텍스트)만으로 찾는 모델이라 오늘 바로 시험할 수 있음. 단 YOLOE·Ultralytics는 AGPL-3.0
→ 시연·내부 평가용(배포 금지). 상업용은 앱이 모은 데이터(equipment_dataset)로 Apache 모델을 학습해 같은 자리를 바꿈.

    (ultralytics 설치한 파이썬) tool/equipment_model.py try   [사진·동영상·폴더...]  # PC에서 결과 그림 → build/equipment_model/try/
    (ultralytics 설치한 파이썬) tool/equipment_model.py export                  # → android/app/src/main/assets/equipment.onnx
    (ultralytics 설치한 파이썬) tool/equipment_model.py eval  <equipment_dataset 폴더> [--weights 모델]  # Gemini 박스를 정답 삼아 재현율·정밀도
    (ultralytics 설치한 파이썬) tool/equipment_model.py train <equipment_dataset 폴더>  # 모은 데이터로 학습 → assets/equipment.onnx

클래스 순서는 lib/analysis/hazard.dart 의 Equipment.labels 와 같아야 함(앱이 번호로 이름을 붙임).
"""
import argparse
import os
import shutil
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / 'build' / 'equipment_model'
ASSET = ROOT / 'android' / 'app' / 'src' / 'main' / 'assets' / 'equipment.onnx'

# 앱 설비 클래스(순서 = 클래스 번호, lib/analysis/hazard.dart 의 Equipment.labels 와 같게)
KEYS = ['valve', 'pipe', 'pump', 'motor', 'electrical_panel', 'gauge', 'fire_extinguisher',
        'tank', 'duct', 'cable_tray']
# 모델 출력 번호 → (설비, YOLOE에 넣을 영어 표현). 한 설비를 여러 표현으로 찾으면 더 잘 잡힘
# (공개 사진 5장에서 표현 하나씩 10개 → 25개로 찾은 수 10 → 14, 분전반 점수 0.21 → 0.64)
PROMPTS = [
    ('valve', 'valve'), ('valve', 'gate valve'), ('valve', 'valve handwheel'), ('valve', 'ball valve'),
    ('pipe', 'pipe'), ('pipe', 'metal pipe'), ('pipe', 'insulated pipe'), ('pipe', 'pipeline'),
    ('pump', 'pump'), ('pump', 'water pump'), ('motor', 'electric motor'),
    ('electrical_panel', 'electrical panel'), ('electrical_panel', 'electrical cabinet'),
    ('electrical_panel', 'switchboard'), ('electrical_panel', 'control panel'),
    ('electrical_panel', 'circuit breaker panel'),
    ('gauge', 'pressure gauge'), ('gauge', 'gauge'), ('gauge', 'thermometer'),
    ('fire_extinguisher', 'fire extinguisher'), ('tank', 'tank'), ('tank', 'water heater'),
    ('duct', 'air duct'), ('duct', 'ventilation duct'), ('cable_tray', 'cable tray'),
]
WEIGHTS = 'yoloe-26s-seg.pt'  # YOLOE-26: 끝단 NMS라 폰 후처리가 가벼움
# 폰 화면은 세로 9:16 → 세로로 긴 입력(32의 배수). 320x192는 거의 못 찾아 480x288
IMGSZ = (480, 288)
CONF = 0.15
# 모델 출력 번호 → 앱 클래스 번호(한 줄에 "앱번호 표현"). 앱(EquipmentChannel.kt)이 읽음
LABELS = ASSET.with_name('equipment_labels.txt')


def key_of(c):
    return PROMPTS[int(c)][0]


def load():
    from ultralytics import YOLOE
    model = YOLOE(WEIGHTS)  # 없으면 Ultralytics가 받음(작업 폴더 = build/equipment_model)
    prompts = [p for _, p in PROMPTS]
    try:
        model.set_classes(prompts, model.get_text_pe(prompts))
    except (AttributeError, TypeError):
        model.set_classes(prompts)
    return model


VIDEO = {'.mp4', '.mov', '.avi', '.mkv'}


def cmd_try(paths):
    model = load()
    imgs = []
    for p in paths or [str(ROOT / 'assets' / 'test_frames')]:
        p = Path(p)
        imgs += sorted(p.glob('*.jp*g')) if p.is_dir() else [p]
    out = OUT / 'try'
    out.mkdir(parents=True, exist_ok=True)
    for img in imgs:
        if img.suffix.lower() in VIDEO:
            # 폰 카메라로 찍은 동영상: 박스를 그린 동영상과 프레임당 시간·개수
            n = found = 0
            t = time.perf_counter()
            for r in model.predict(str(img), imgsz=list(IMGSZ), conf=CONF, stream=True,
                                   save=True, project=str(out), name=img.stem, exist_ok=True,
                                   verbose=False):
                n += 1
                found += len(r.boxes)
            ms = (time.perf_counter() - t) * 1000 / max(n, 1)
            print(f'{img.name}: {n}프레임, 프레임당 {ms:.0f}ms (PC CPU), 평균 {found / max(n, 1):.1f}개 → {out / img.stem}')
            continue
        t = time.perf_counter()
        r = model.predict(str(img), imgsz=list(IMGSZ), conf=CONF, verbose=False)[0]
        ms = (time.perf_counter() - t) * 1000
        found = [f'{key_of(c)}({PROMPTS[int(c)][1]}) {s:.2f}' for c, s in zip(r.boxes.cls, r.boxes.conf)]
        print(f'{img.name}: {ms:.0f}ms (PC CPU) · {len(found)}개 {", ".join(found)}')
        r.save(filename=str(out / f'{img.stem}.jpg'))
    print(f'그림: {out}')


def cmd_export():
    model = load()
    # 폰은 ONNX Runtime으로 돌림: Ultralytics의 TFLite(LiteRT) 내보내기는 리눅스·맥 전용이고,
    # 나중에 바꿀 Apache 모델(D-FINE 등)도 ONNX로 공식 배포됨
    src = Path(model.export(format='onnx', imgsz=list(IMGSZ), simplify=True))
    ASSET.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(src, ASSET)
    LABELS.write_text(''.join(f'{KEYS.index(k)} {p}\n' for k, p in PROMPTS), encoding='utf-8')
    print(f'{src} → {ASSET} ({ASSET.stat().st_size / 1e6:.1f}MB), {LABELS.name} {len(PROMPTS)}줄')

    # 내보낸 ONNX가 PC에서도 같은 결과를 내는지 확인
    import numpy as np
    import onnxruntime as ort
    sess = ort.InferenceSession(str(ASSET), providers=['CPUExecutionProvider'])
    inp = sess.get_inputs()[0]
    print(f'  입력 {inp.name} {inp.shape}, 출력 {[(o.name, o.shape) for o in sess.get_outputs()]}')
    x = np.zeros([1, 3, *IMGSZ], np.float32)
    t = time.perf_counter()
    for _ in range(5):
        sess.run(None, {inp.name: x})
    print(f'  PC CPU 추론 {(time.perf_counter() - t) * 200:.0f}ms/장')
    from ultralytics import YOLO
    lite = YOLO(str(ASSET), task='segment')  # 출력에 마스크 계수가 붙어 있음(앱은 무시)
    for img in sorted((OUT / 'samples').glob('*.jpg')):
        r = lite.predict(str(img), imgsz=list(IMGSZ), conf=CONF, verbose=False)[0]
        print(f'  ONNX {img.name}: ' + ', '.join(
            f'{key_of(c)} {s:.2f}' for c, s in zip(r.boxes.cls, r.boxes.conf)))


def iou(a, b):
    iw = min(a[2], b[2]) - max(a[0], b[0])
    ih = min(a[3], b[3]) - max(a[1], b[1])
    if iw <= 0 or ih <= 0:
        return 0.0
    inter = iw * ih
    return inter / ((a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter)


def cmd_train(root, base, epochs, keep_app_model=False):
    """앱이 모은 데이터(Gemini 박스)로 작은 YOLO를 학습(PC CPU) → ONNX로 앱 assets에 넣음.
    사진 5장마다 1장은 검증용. Ultralytics(AGPL)라 시연용이고, 상업용은 같은 데이터로 Apache 모델을 학습."""
    from ultralytics import YOLO
    root = Path(root)
    imgs = sorted((root / 'images').glob('*.jpg'))
    if len(imgs) < 10:
        sys.exit(f'사진이 {len(imgs)}장뿐: 최소 10장(권장 수백 장) 모은 뒤 학습하세요')
    work = OUT / 'train'
    work.mkdir(parents=True, exist_ok=True)
    val = [p for i, p in enumerate(imgs) if i % 5 == 4]
    train = [p for p in imgs if p not in val]
    (work / 'train.txt').write_text('\n'.join(str(p) for p in train), encoding='utf-8')
    (work / 'val.txt').write_text('\n'.join(str(p) for p in val), encoding='utf-8')
    names = '\n'.join(f'  {i}: {k}' for i, k in enumerate(KEYS))
    data = work / 'data.yaml'
    data.write_text(f'train: {work / "train.txt"}\nval: {work / "val.txt"}\nnames:\n{names}\n',
                    encoding='utf-8')
    print(f'학습 {len(train)}장 · 검증 {len(val)}장 · 기본 모델 {base} · {epochs}회')
    model = YOLO(base)
    model.train(data=str(data), imgsz=max(IMGSZ), epochs=epochs, batch=8, device='cpu', workers=0,
                project=str(work), name='run', exist_ok=True, plots=False)
    best = YOLO(str(work / 'run' / 'weights' / 'best.pt'))
    src = Path(best.export(format='onnx', imgsz=list(IMGSZ), simplify=True))
    if keep_app_model:
        print(f'학습한 모델: {src} (앱 모델은 그대로. 평가: eval <데이터> --weights {src})')
        return
    shutil.copyfile(src, ASSET)
    LABELS.write_text(''.join(f'{i} {k}\n' for i, k in enumerate(KEYS)), encoding='utf-8')
    print(f'{src} → {ASSET} ({ASSET.stat().st_size / 1e6:.1f}MB). 앱을 다시 빌드하면 이 모델로 바뀜')


def cmd_eval(root, weights=None):
    """앱이 모은 데이터(Gemini 박스)를 정답 삼아, 클래스별 재현율(정답 중 찾은 비율)·정밀도(찾은 것 중 맞은 비율), IoU≥0.5.
    weights를 주면 학습한 모델(출력 번호 = 설비 번호), 아니면 YOLOE(여러 표현)"""
    root = Path(root)
    if weights:
        from ultralytics import YOLO
        model = YOLO(weights)
    else:
        model = load()
    names = KEYS
    tp = {n: 0 for n in names}
    gt_n = {n: 0 for n in names}
    pr_n = {n: 0 for n in names}
    for img in sorted((root / 'images').glob('*.jpg')):
        gt = []
        for row in (root / 'labels' / f'{img.stem}.txt').read_text(encoding='utf-8').splitlines():
            c, cx, cy, w, h = row.split()
            cx, cy, w, h = map(float, (cx, cy, w, h))
            gt.append((int(c), (cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2)))
        r = model.predict(str(img), imgsz=list(IMGSZ), conf=CONF, verbose=False)[0]
        pred = [(int(c) if weights else KEYS.index(key_of(c)), tuple(b))
                for c, b in zip(r.boxes.cls.tolist(), r.boxes.xyxyn.tolist())]
        used = set()
        for c, b in gt:
            gt_n[names[c]] += 1
        for c, b in pred:
            pr_n[names[c]] += 1
            best = max(((iou(b, g), i) for i, (gc, g) in enumerate(gt) if gc == c and i not in used),
                       default=(0, -1))
            if best[0] >= 0.5:
                used.add(best[1])
                tp[names[c]] += 1
    print('클래스 | 정답 | 찾음 | 맞음 | 재현율 | 정밀도')
    for n in names:
        if gt_n[n] or pr_n[n]:
            rec = tp[n] / gt_n[n] if gt_n[n] else 0
            pre = tp[n] / pr_n[n] if pr_n[n] else 0
            print(f'{n} | {gt_n[n]} | {pr_n[n]} | {tp[n]} | {rec:.0%} | {pre:.0%}')


def main():
    for s in (sys.stdout, sys.stderr):
        s.reconfigure(encoding='utf-8', errors='replace')
    ap = argparse.ArgumentParser(description='설비 전용 탐지기(YOLOE 시험) 만들기')
    sub = ap.add_subparsers(dest='cmd', required=True)
    t = sub.add_parser('try', help='PC에서 사진에 돌려 결과 그림 저장')
    t.add_argument('paths', nargs='*')
    sub.add_parser('export', help='YOLOE를 폰용 ONNX로 내보내 앱 assets에 복사')
    tr = sub.add_parser('train', help='앱이 모은 데이터로 작은 YOLO 학습 → 앱 assets에 복사')
    tr.add_argument('dataset')
    tr.add_argument('--base', default='yolo26n.pt', help='시작 모델(처음 쓰면 Ultralytics가 받음)')
    tr.add_argument('--epochs', type=int, default=60)
    tr.add_argument('--keep-app-model', action='store_true', help='학습만 하고 앱 assets 모델은 그대로')
    e = sub.add_parser('eval', help='앱이 모은 Gemini 박스를 정답 삼아 평가')
    e.add_argument('dataset')
    e.add_argument('--weights', help='학습한 모델(.pt/.onnx). 비우면 YOLOE')
    a = ap.parse_args()
    if a.cmd == 'try':
        a.paths = [str(Path(p).resolve()) for p in a.paths]
    if a.cmd in ('eval', 'train'):
        a.dataset = str(Path(a.dataset).resolve())
    if getattr(a, 'weights', None):
        a.weights = str(Path(a.weights).resolve())
    OUT.mkdir(parents=True, exist_ok=True)
    os.chdir(OUT)  # 받는 모델·내보내기 결과가 프로젝트 build 폴더에 모이게
    {'try': lambda: cmd_try(a.paths), 'export': cmd_export,
     'train': lambda: cmd_train(a.dataset, a.base, a.epochs, a.keep_app_model),
     'eval': lambda: cmd_eval(a.dataset, a.weights)}[a.cmd]()


if __name__ == '__main__':
    main()
