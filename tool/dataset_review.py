"""설비 학습 데이터(앱이 YOLO 형식으로 쌓은 것) 검수용 HTML 만들기.

    adb pull /sdcard/Android/data/com.example.facility_camera/files/equipment_dataset build/equipment_dataset
    python tool/dataset_review.py build/equipment_dataset

→ <폴더>/review.html 을 브라우저로 열면 사진마다 Gemini가 짚은 설비 박스가 겹쳐 보입니다.
틀린 사진은 images/·labels/ 에서 같은 이름 두 파일을 지우거나 labels/*.txt 를 고치면 됩니다.
외부 라이브러리 없이 동작(그림은 브라우저가 겹쳐 그림).
"""
import html
import json
import sys
from collections import Counter
from pathlib import Path

NAMES = {
    'valve': '밸브', 'pipe': '배관', 'pump': '펌프', 'motor': '모터',
    'electrical_panel': '분전반·제어반', 'gauge': '계기', 'fire_extinguisher': '소화기',
    'tank': '탱크', 'duct': '덕트', 'cable_tray': '케이블트레이',
}
COLORS = ['#e6194b', '#3cb44b', '#ffe119', '#4363d8', '#f58231',
          '#911eb4', '#42d4f4', '#f032e6', '#bfef45', '#fabed4']


def main(root: Path) -> None:
    classes = (root / 'classes.txt').read_text(encoding='utf-8').split()
    places = {}
    meta = root / 'samples.jsonl'
    if meta.exists():
        for line in meta.read_text(encoding='utf-8').splitlines():
            if line.strip():
                r = json.loads(line)
                places[Path(r['image']).stem] = r.get('place', '')

    counts = Counter()
    cards = []
    for img in sorted((root / 'images').glob('*.jpg')):
        label = root / 'labels' / f'{img.stem}.txt'
        boxes = []
        if label.exists():
            for row in label.read_text(encoding='utf-8').splitlines():
                p = row.split()
                if len(p) != 5:
                    continue
                c = int(p[0])
                cx, cy, w, h = map(float, p[1:])
                name = classes[c] if c < len(classes) else str(c)
                counts[name] += 1
                color = COLORS[c % len(COLORS)]
                boxes.append(
                    f'<div class="b" style="left:{(cx - w / 2) * 100:.2f}%;top:{(cy - h / 2) * 100:.2f}%;'
                    f'width:{w * 100:.2f}%;height:{h * 100:.2f}%;border-color:{color}">'
                    f'<span style="background:{color}">{html.escape(NAMES.get(name, name))}</span></div>')
        place = html.escape(places.get(img.stem, ''))
        cards.append(
            f'<figure><div class="p"><img src="images/{img.name}" loading="lazy">{"".join(boxes)}</div>'
            f'<figcaption>{img.stem} · {place} · 박스 {len(boxes)}개</figcaption></figure>')

    summary = ', '.join(f'{NAMES.get(k, k)} {v}' for k, v in counts.most_common())
    out = root / 'review.html'
    out.write_text(f'''<!doctype html><meta charset="utf-8"><title>설비 학습 데이터 검수</title>
<style>
body{{font-family:sans-serif;margin:16px;background:#f4f4f4}}
.grid{{display:grid;grid-template-columns:repeat(auto-fill,minmax(320px,1fr));gap:12px}}
figure{{margin:0;background:#fff;padding:6px;border-radius:6px}}
.p{{position:relative}} .p img{{width:100%;display:block}}
.b{{position:absolute;border:2px solid;box-sizing:border-box}}
.b span{{position:absolute;left:-2px;top:-1.4em;font-size:12px;color:#000;padding:0 3px;white-space:nowrap}}
figcaption{{font-size:12px;color:#555;margin-top:4px}}
</style>
<h1>설비 학습 데이터 검수</h1>
<p>사진 {len(cards)}장 · {html.escape(summary) or '박스 없음'}</p>
<div class="grid">{"".join(cards)}</div>
''', encoding='utf-8')
    print(f'사진 {len(cards)}장, {summary}')
    print(f'열기: {out.resolve()}')


if __name__ == '__main__':
    for s in (sys.stdout, sys.stderr):
        s.reconfigure(encoding='utf-8', errors='replace')
    if len(sys.argv) != 2:
        sys.exit('사용법: python tool/dataset_review.py <equipment_dataset 폴더>')
    main(Path(sys.argv[1]))
