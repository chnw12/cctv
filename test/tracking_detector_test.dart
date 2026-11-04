import 'dart:ui';
import 'package:facility_camera/core/frame.dart';
import 'package:facility_camera/detection/detector.dart';
import 'package:facility_camera/detection/hungarian.dart';
import 'package:facility_camera/detection/kalman.dart';
import 'package:facility_camera/detection/tracking_detector.dart';
import 'package:flutter_test/flutter_test.dart';

/// 미리 정한 박스 목록을 차례로 돌려주는 가짜 탐지기
class _Scripted implements Detector {
  _Scripted(this.frames);
  final List<List<Rect>> frames;
  int _i = 0;

  @override
  Future<List<Detection>> detect(Frame frame) async => frames[_i++]
      .map((b) => Detection(trackingId: null, box: b, label: '', confidence: 0))
      .toList();

  @override
  Future<void> close() async {}
}

Frame _at(int ms) =>
    Frame.file(timestampMs: ms, filePath: '', uprightSize: const Size(1, 1));

void main() {
  group('TrackingDetector', () {
    test('조금씩 움직이는 물체는 같은 ID, 새 물체는 새 ID', () async {
      final t = TrackingDetector(
          _Scripted([
            [const Rect.fromLTWH(0.1, 0.1, 0.2, 0.2)],
            [
              const Rect.fromLTWH(0.12, 0.11, 0.2, 0.2),
              const Rect.fromLTWH(0.6, 0.6, 0.2, 0.2),
            ],
          ]),
          minHits: 1,
          minConfirmMs: 0);
      final a = await t.detect(_at(0));
      final b = await t.detect(_at(200));
      expect(b[0].trackingId, a[0].trackingId);
      expect(b[1].trackingId, isNot(a[0].trackingId));
    });

    test('처리 1FPS(프레임 간격 1.5초)여도 계속 보이는 물체는 ID 유지', () async {
      const box = Rect.fromLTWH(0.1, 0.1, 0.2, 0.2);
      final t = TrackingDetector(_Scripted(List.filled(10, [box])),
          minHits: 1, minConfirmMs: 0);
      final ids = <int?>{};
      for (var i = 0; i < 10; i++) {
        ids.add((await t.detect(_at(i * 1500))).single.trackingId);
      }
      expect(ids, {1}); // 이전 구현은 매 프레임 새 ID였음
    });

    test('짧게 가려졌다 다시 보이면 같은 ID, 프레임·시간 둘 다 넘게 사라지면 새 ID', () async {
      const box = Rect.fromLTWH(0.1, 0.1, 0.2, 0.2);
      final t = TrackingDetector(
          _Scripted([
            [box], [], [], [box], // 2프레임 가림 → 유지
            [], [], [], [], [], [box], // 5프레임(>3) & 2.5초(>2초) → 폐기
          ]),
          minHits: 1,
          minConfirmMs: 0,
          maxMissFrames: 3,
          maxMissMs: 2000);
      final a = await t.detect(_at(0));
      await t.detect(_at(500));
      await t.detect(_at(1000));
      final d = await t.detect(_at(1500));
      expect(d.single.trackingId, a.single.trackingId);
      for (final ms in [2000, 2500, 3000, 3500, 4000]) {
        await t.detect(_at(ms)); // 4000ms: 5프레임 놓침 & 2.5초 → 여기서 폐기
      }
      final i = await t.detect(_at(4500));
      expect(i.single.trackingId, isNot(a.single.trackingId));
    });

    test('minHits 전에는 ID 없음, 한 프레임 오탐은 끝까지 ID 없음', () async {
      const box = Rect.fromLTWH(0.1, 0.1, 0.2, 0.2);
      const blip = Rect.fromLTWH(0.7, 0.7, 0.1, 0.1);
      final t = TrackingDetector(
          _Scripted([
            [box, blip],
            [box],
            [box],
          ]),
          minHits: 3,
          minConfirmMs: 0);
      final a = await t.detect(_at(0));
      final b = await t.detect(_at(100));
      final c = await t.detect(_at(200));
      expect(a.map((d) => d.trackingId), [null, null]);
      expect(b.single.trackingId, isNull);
      expect(c.single.trackingId, 1);
    });

    test('ID는 3번 이상·0.4초 이상 잡혀야, 미확정은 1번 놓침까지 살림(2번 연달아면 처음부터)', () async {
      const box = Rect.fromLTWH(0.1, 0.1, 0.2, 0.2);
      Future<List<int?>> run(List<bool> seen) async {
        final t = TrackingDetector(_Scripted([
          for (final v in seen) v ? [box] : <Rect>[]
        ]));
        return [
          for (var i = 0; i < seen.length; i++)
            (await t.detect(_at(i * 100))).firstOrNull?.trackingId
        ];
      }

      // 매 프레임(100ms): 0.4초가 되는 5번째에 ID
      expect(await run(List.filled(6, true)), [null, null, null, null, 1, 1]);
      // 중간에 한 번 놓쳐도 이어서 0.4초에 ID
      expect(await run([true, true, false, true, true, true]),
          [null, null, null, null, 1, 1]);
      // 두 번 연달아 놓치면 버리고 다시 셈 → 다시 0.4초
      expect(
          (await run([true, true, false, false, true, true, true, true, true]))
              .last,
          1);
      expect(
          (await run([true, true, false, false, true, true, true, true])).last,
          isNull);
    });

    test('빠르게 움직여 직전 박스와 안 겹쳐도 칼만 예측 위치로 이어짐', () async {
      // 초당 0.3씩 등속 이동(폭 0.2). 처음엔 0.1초 간격으로 속도를 학습하고,
      // 뒤에는 0.5초 간격 → 직전 박스와 0.15 차이, IoU 0.14 < 0.3
      final times = [0, 100, 200, 300, 800, 1300, 1800, 2300];
      final frames = [
        for (final ms in times)
          [Rect.fromLTWH(0.05 + 0.3 * ms / 1000, 0.4, 0.2, 0.2)]
      ];
      final t =
          TrackingDetector(_Scripted(frames), minHits: 1, minConfirmMs: 0);
      final ids = <int?>{};
      for (final ms in times) {
        ids.add((await t.detect(_at(ms))).single.trackingId);
      }
      expect(ids.length, 1);
    });

    test('IoU 계산', () {
      const a = Rect.fromLTWH(0, 0, 2, 2);
      expect(TrackingDetector.iou(a, a), 1);
      expect(TrackingDetector.iou(a, const Rect.fromLTWH(1, 0, 2, 2)),
          closeTo(1 / 3, 1e-9));
      expect(TrackingDetector.iou(a, const Rect.fromLTWH(5, 5, 1, 1)), 0);
    });
  });

  group('hungarian', () {
    test('탐욕 매칭이면 틀리는 경우도 전체 최소 비용을 찾음', () {
      // 탐욕: (0,0)=1 먼저 → 남은 (1,1)=10 → 합 11 / 최적: (0,1)+(1,0) = 2+2 = 4
      expect(
          hungarian([
            [1, 2],
            [2, 10],
          ]),
          [1, 0]);
    });

    test('행·열 수가 달라도 됨', () {
      expect(
          hungarian([
            [5, 1, 9],
          ]),
          [1]);
      expect(
          hungarian([
            [5],
            [1],
            [9],
          ]),
          [-1, 0, -1]);
      expect(hungarian([]), isEmpty);
    });
  });

  group('Kalman', () {
    test('등속 이동하는 박스의 속도를 학습해 다음 위치를 예측', () {
      final k = BoxKalman(const Rect.fromLTWH(0.1, 0.4, 0.2, 0.2));
      for (var i = 1; i <= 10; i++) {
        k.predict(0.1);
        k.update(Rect.fromLTWH(0.1 + 0.03 * i, 0.4, 0.2, 0.2)); // 0.3/초
      }
      k.predict(1.0);
      // 1초 뒤 실제 위치 cx = 0.2 + 0.3 + 0.3 = 0.8
      expect(k.box.center.dx, closeTo(0.8, 0.05));
      expect(k.box.center.dy, closeTo(0.5, 0.01));
    });

    test('떨리는 측정을 평균내 덜 떨림', () {
      final k = BoxKalman(const Rect.fromLTWH(0.4, 0.4, 0.2, 0.2));
      var maxDev = 0.0;
      for (var i = 0; i < 30; i++) {
        k.predict(0.033);
        final jitter = (i.isEven ? 1 : -1) * 0.01;
        k.update(Rect.fromLTWH(0.4 + jitter, 0.4, 0.2, 0.2));
        if (i > 5) {
          final dev = (k.box.center.dx - 0.5).abs();
          if (dev > maxDev) maxDev = dev;
        }
      }
      expect(maxDev, lessThan(0.01)); // 측정 떨림 ±0.01보다 작게
    });
  });
}
