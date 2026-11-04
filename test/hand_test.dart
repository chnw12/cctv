import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';
import 'package:facility_camera/analysis/hazard.dart';
import 'package:facility_camera/core/frame.dart';
import 'package:facility_camera/hands/hand_pointer.dart';
import 'package:facility_camera/hands/hand_tracker.dart';
import 'package:facility_camera/ui/box_painter.dart';
import 'package:flutter_test/flutter_test.dart';

/// 센서 방향 4x2 NV21: 밝기는 (x, y)마다 다르게, 색은 회색(128)
Frame _nv21(int rot, {int w = 4, int h = 2, bool color = false}) {
  final b = Uint8List(w * h * 3 ~/ 2)..fillRange(w * h, w * h * 3 ~/ 2, 128);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      b[y * w + x] = 10 + 40 * y + 10 * x;
    }
  }
  if (color) {
    // 왼쪽 위 2x2 블록: V=200(빨강 쪽), U=128
    b[w * h] = 200;
  }
  final turned = rot == 90 || rot == 270;
  return Frame.raw(
      timestampMs: 0,
      format: FrameFormat.nv21,
      bytes: b,
      rawSize: Size(w.toDouble(), h.toDouble()),
      rotationDegrees: rot,
      bytesPerRow: w,
      uprightSize: turned
          ? Size(h.toDouble(), w.toDouble())
          : Size(w.toDouble(), h.toDouble()));
}

List<int> _luma(({Uint8List rgba, int width, int height}) img) =>
    [for (var i = 0; i < img.rgba.length; i += 4) img.rgba[i]];

HandLandmarks _hand(Offset tip, {Offset wrist = const Offset(0.5, 0.95)}) =>
    HandLandmarks([
      for (var i = 0; i < 21; i++)
        i == HandLandmarks.indexTip
            ? tip
            : (i == HandLandmarks.wrist ? wrist : wrist)
    ]);

void main() {
  test('NV21 → 똑바로 선 RGBA: 회전별로 센서 점이 맞는 자리에(센서 위 왼쪽이 90°면 오른쪽 위)', () {
    // 센서 밝기 (x,y): 행0 = 10 20 30 40, 행1 = 50 60 70 80
    final r0 = uprightRgba(_nv21(0), step: 1)!;
    expect((r0.width, r0.height), (4, 2));
    expect(_luma(r0), [10, 20, 30, 40, 50, 60, 70, 80]);

    // 90°(폰 후면 카메라): 똑바로 선 영상은 2x4, 센서 맨 왼쪽 열(10,50)이 맨 위 행(오른쪽→왼쪽)
    final r90 = uprightRgba(_nv21(90), step: 1)!;
    expect((r90.width, r90.height), (2, 4));
    expect(_luma(r90), [50, 10, 60, 20, 70, 30, 80, 40]);

    final r180 = uprightRgba(_nv21(180), step: 1)!;
    expect(_luma(r180), [80, 70, 60, 50, 40, 30, 20, 10]);

    final r270 = uprightRgba(_nv21(270), step: 1)!;
    expect(_luma(r270), [40, 80, 30, 70, 20, 60, 10, 50]);

    // 줄이기: 2칸마다 가운데 점
    final half = uprightRgba(_nv21(0, w: 4, h: 4), step: 2)!;
    expect((half.width, half.height), (2, 2));

    // 파일 프레임(테스트 이미지)은 없음
    expect(
        uprightRgba(const Frame.file(
            timestampMs: 0, filePath: '', uprightSize: Size(1, 1))),
        isNull);
  });

  test('색 변환: V가 크면 빨강 쪽, 회색(128)이면 R=G=B, 알파 255', () {
    final img = uprightRgba(_nv21(0, color: true), step: 1)!;
    final px = img.rgba.sublist(0, 4); // (0,0): Y=10, V=200
    expect(px[0], greaterThan(px[2]), reason: 'R > B');
    expect(px[3], 255);
    final gray = img.rgba.sublist(4 * 2, 4 * 3); // (2,0): 다른 색 블록 = 회색
    expect(gray[0], gray[1]);
    expect(gray[1], gray[2]);
  });

  test('채널 응답 → 관절점, 손이 둘이면 손가락을 더 뻗은 손이 포인터', () {
    final flat = [
      for (var i = 0; i < 21; i++) ...[i / 100, i / 50, 0.0]
    ];
    final h = HandLandmarks.fromFlat(flat);
    expect(h.points, hasLength(21));
    expect(h.tip, const Offset(0.08, 0.16));

    final short = _hand(const Offset(0.5, 0.8));
    final long = _hand(const Offset(0.3, 0.2));
    expect(HandFrame(0, [short, long]).pointer, same(long));
    expect(const HandFrame(0, []).pointer, isNull);
  });

  test('1€ 필터: 멈춘 손끝 떨림은 줄이고, 크게 움직이면 금방 따라감', () {
    final f = OneEuroFilter();
    var t = 0.0, y = 0.0;
    var maxJitter = 0.0;
    for (var i = 0; i < 30; i++) {
      t += 0.1;
      y = f.filter(0.5 + (i.isEven ? 0.01 : -0.01), t); // ±0.01 떨림
      if (i > 5) maxJitter = math.max(maxJitter, (y - 0.5).abs());
    }
    expect(maxJitter, lessThan(0.006), reason: '떨림 절반 이하로');
    for (var i = 0; i < 6; i++) {
      t += 0.1;
      y = f.filter(0.9, t); // 0.4 점프
    }
    expect(y, greaterThan(0.85), reason: '0.6초 안에 거의 따라감');
  });

  group('손가락 포인터(머무르기)', () {
    const view = Size(400, 800);
    final hazards = {0: const Rect.fromLTWH(100, 300, 100, 100)};
    final layout = HazardActionLayout.of(hazards[0]!, view);
    Offset norm(Offset px) => Offset(px.dx / view.width, px.dy / view.height);

    test('박스 위 0.3초 → 선택, 버튼 위 1초 → 누름, 누른 뒤 잠깐 쉼', () {
      final p = HandPointer();
      HandEvent? last;
      for (var ms = 0; ms <= 300; ms += 100) {
        last =
            p.update(ms, norm(const Offset(150, 350)), view, hazards: hazards);
        if (ms < 300) {
          expect(last, isNull);
          expect(p.target, HandTarget.hazard);
        }
      }
      expect(last, isA<SelectHazard>().having((e) => e.index, 'index', 0));

      // 선택된 뒤: [완료] 버튼으로 옮겨 1초(손끝 필터가 따라오는 몇 프레임 + 1초 안에 눌림)
      final done = norm(layout.done.center);
      HandEvent? press;
      var pressedAt = 0;
      for (var ms = 400; ms <= 2500 && press == null; ms += 100) {
        press = p.update(ms, done, view,
            hazards: hazards, selected: 0, layout: layout);
        pressedAt = ms;
      }
      expect(
          press,
          isA<PressAction>()
              .having((e) => e.action, 'action', HazardStatus.resolved));
      expect(pressedAt, inInclusiveRange(1400, 1800));

      // 바로 뒤에는 같은 자리에 있어도 안 눌림(0.8초 쉼)
      expect(
          p.update(pressedAt + 100, done, view,
              hazards: hazards, selected: 0, layout: layout),
          isNull);
      expect(p.target, HandTarget.none);
    });

    test('버튼에서 벗어나면 취소, [무시]로 옮기면 처음부터, 폰이 돌면 진행 안 함', () {
      final p = HandPointer();
      final ignore = norm(layout.ignore.center);
      final done = norm(layout.done.center);
      p.update(0, done, view, hazards: hazards, selected: 0, layout: layout);
      p.update(600, done, view, hazards: hazards, selected: 0, layout: layout);
      expect(p.progress, closeTo(0.6, 0.01));
      // 무시 버튼으로 옮김 → 다시 0부터(필터가 따라오는 데 몇 프레임)
      for (var ms = 700; ms <= 1500; ms += 100) {
        p.update(ms, ignore, view,
            hazards: hazards, selected: 0, layout: layout);
      }
      expect(p.target, HandTarget.ignore);
      expect(p.progress, lessThan(1));
      // 폰이 빠르게 도는 중엔 진행 0
      p.update(1600, ignore, view,
          hazards: hazards, selected: 0, layout: layout, moving: true);
      expect(p.progress, 0);
    });

    test('손이 잠깐(0.5초 이하) 안 보이면 기다리고, 오래 없으면 커서·진행 초기화', () {
      final p = HandPointer();
      p.update(0, norm(const Offset(150, 350)), view, hazards: hazards);
      p.update(100, null, view, hazards: hazards);
      expect(p.tip, isNotNull);
      p.update(700, null, view, hazards: hazards);
      expect(p.tip, isNull);
      expect(p.target, HandTarget.none);
    });
  });
}
