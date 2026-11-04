"""앱의 시험용 녹화(설정 → 개발자 → 녹화 버튼 보이기)를 PC에서 다루기.

    adb pull /sdcard/Android/data/com.example.facility_camera/files/recordings build/recordings
    <opencv 있는 파이썬> tool/recording_tool.py info   build/recordings/<녹화>
    <opencv 있는 파이썬> tool/recording_tool.py video  build/recordings/<녹화> [--boxes]   # → <녹화>.mp4
    <opencv 있는 파이썬> tool/recording_tool.py frames build/recordings/<녹화> --every 15  # → <녹화>_frames/*.jpg

- video: 똑바로 세운 동영상(녹화 시간 간격 그대로). --boxes면 그 순간 원본 탐지 박스(추적 전)를 겹쳐 그림
- frames: N장마다 똑바로 세운 사진. 탐지기 평가·학습(tool/equipment_model.py)이나 앱 "테스트 이미지"(adb push)에 씀
- 녹화 log.jsonl은 분석 로그 형식이라 추적기 재생 테스트에도 그대로 씀:
    flutter test test/replay_log_test.dart --dart-define=REPLAY_LOG=build/recordings/<녹화>/log.jsonl -r expanded
opencv는 tool/equipment_model.py용 ultralytics 가상환경에 들어 있음.
"""
import argparse
import json
import sys
from pathlib import Path


def load(root: Path):
    meta, imgs, gyro, dets = {}, [], 0, {}
    for line in (root / 'log.jsonl').read_text(encoding='utf-8').splitlines():
        if not line.strip():
            continue
        m = json.loads(line)
        k = m.get('k')
        if k == 'meta':
            meta = m
        elif k == 'img':
            imgs.append((m['t'], m['f']))
        elif k == 'g':
            gyro += 1
        elif k == 'f':
            dets[m['t']] = m['d']
    return meta, imgs, gyro, dets


def upright(img, rotation):
    import cv2
    return {90: lambda i: cv2.rotate(i, cv2.ROTATE_90_CLOCKWISE),
            180: lambda i: cv2.rotate(i, cv2.ROTATE_180),
            270: lambda i: cv2.rotate(i, cv2.ROTATE_90_COUNTERCLOCKWISE)}.get(rotation, lambda i: i)(img)


def cmd_info(root: Path):
    meta, imgs, gyro, dets = load(root)
    secs = (imgs[-1][0] - imgs[0][0]) / 1000 if len(imgs) > 1 else 0
    summary = root / 'summary.json'
    dropped = json.loads(summary.read_text())['dropped'] if summary.exists() else '?'
    size = sum(p.stat().st_size for p in (root / 'frames').glob('*.jpg'))
    print(f'{root.name}: {len(imgs)}장 · {secs:.1f}초 · 평균 {len(imgs) / max(secs, 1e-6):.1f}장/초 · 건너뜀 {dropped}')
    print(f'  자이로 {gyro}개({gyro / max(secs, 1e-6):.0f}Hz) · 원본 탐지 {len(dets)}프레임 · 사진 {size / 1e6:.0f}MB')
    print(f'  회전 {meta.get("rotation")}° · 원본 {meta.get("rawW")}x{meta.get("rawH")} · 탐지기 {meta.get("detector")}'
          f' · 해상도 {meta.get("preset")} · 시작 {meta.get("started")}')


def cmd_video(root: Path, boxes: bool):
    import cv2
    meta, imgs, _, dets = load(root)
    rot = int(meta.get('rotation', 0))
    secs = (imgs[-1][0] - imgs[0][0]) / 1000 if len(imgs) > 1 else 1
    fps = max(1.0, (len(imgs) - 1) / secs)
    out = root.with_suffix('.mp4')
    writer = None
    for t, name in imgs:
        img = cv2.imread(str(root / name))
        if img is None:
            continue
        img = upright(img, rot)
        h, w = img.shape[:2]
        if writer is None:
            writer = cv2.VideoWriter(str(out), cv2.VideoWriter_fourcc(*'mp4v'), fps, (w, h))
        if boxes:
            for l, tp, r, b, *_ in dets.get(t, []):
                cv2.rectangle(img, (int(l * w), int(tp * h)), (int(r * w), int(b * h)), (0, 255, 255), 2)
        writer.write(img)
    if writer is None:
        sys.exit('사진을 읽지 못했습니다')
    writer.release()
    print(f'{out} ({fps:.1f}장/초, {len(imgs)}장)')


def cmd_frames(root: Path, every: int):
    import cv2
    meta, imgs, _, _ = load(root)
    rot = int(meta.get('rotation', 0))
    out = root.parent / f'{root.name}_frames'
    out.mkdir(exist_ok=True)
    n = 0
    for i, (t, name) in enumerate(imgs):
        if i % every:
            continue
        img = cv2.imread(str(root / name))
        if img is None:
            continue
        cv2.imwrite(str(out / f'{root.name}_{t}.jpg'), upright(img, rot), [cv2.IMWRITE_JPEG_QUALITY, 90])
        n += 1
    print(f'{out} ({n}장)')


def main():
    for s in (sys.stdout, sys.stderr):
        s.reconfigure(encoding='utf-8', errors='replace')
    ap = argparse.ArgumentParser(description='앱 시험용 녹화 다루기')
    sub = ap.add_subparsers(dest='cmd', required=True)
    sub.add_parser('info', help='길이·장수·자이로 등 요약').add_argument('recording')
    v = sub.add_parser('video', help='똑바로 세운 MP4로')
    v.add_argument('recording')
    v.add_argument('--boxes', action='store_true', help='원본 탐지 박스를 겹쳐 그림')
    f = sub.add_parser('frames', help='N장마다 똑바로 세운 사진으로')
    f.add_argument('recording')
    f.add_argument('--every', type=int, default=15)
    a = ap.parse_args()
    root = Path(a.recording)
    if not (root / 'log.jsonl').exists():
        sys.exit(f'녹화 폴더가 아닙니다(log.jsonl 없음): {root}')
    {'info': lambda: cmd_info(root), 'video': lambda: cmd_video(root, a.boxes),
     'frames': lambda: cmd_frames(root, a.every)}[a.cmd]()


if __name__ == '__main__':
    main()
