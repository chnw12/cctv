import 'dart:math' as math;
import 'dart:ui';
import 'package:facility_camera/detection/tracking_detector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/baseline_iou_tracker.dart';
import 'support/scenario.dart';

/// 자율주행 인지 시나리오 테스트처럼 상황별 합성 장면에서
/// 새 추적기(칼만+헝가리안)와 이전 추적기(IoU 탐욕)를 같은 지표로 비교.
/// `flutter test test/tracking_scenarios_test.dart -r expanded` 로 표를 볼 수 있습니다.

Rect _box(double x, double y, [double s = 0.2]) => Rect.fromLTWH(x, y, s, s);

/// 손에 든 폰을 옆으로 돌릴 때: 0에서 가속해 초당 vmax로 화면이 흐름
double _panShift(double t, {double a = 0.5, double vmax = 0.4}) {
  final tr = vmax / a;
  return t < tr ? a * t * t / 2 : vmax * t - vmax * vmax / (2 * a);
}

final scenarios = <Scenario>[
  Scenario(
    name: '① 정지 장면 · 처리 1FPS (에뮬레이터 실측 버그)',
    objects: [
      GtObject((_) => _box(0.1, 0.3)),
      GtObject((_) => _box(0.55, 0.5, 0.3)),
    ],
    frameTimesMs: randomIntervals(900, 1500, 50),
    missProb: 0.05,
    jitter: 0.03,
  ),
  Scenario(
    name: '② 정지 장면 · 30FPS · 깜빡임 20% · 오탐 10%',
    objects: [
      GtObject((_) => _box(0.1, 0.3)),
      GtObject((_) => _box(0.55, 0.5, 0.3)),
    ],
    frameTimesMs: everyMs(33, 10),
    missProb: 0.2,
    jitter: 0.02,
    falsePosProb: 0.1,
  ),
  Scenario(
    name: '③ 카메라 패닝(벽 따라 설비 훑기) · 2.5FPS',
    objects: [
      for (final x0 in [0.1, 0.4, 0.7, 1.0, 1.3, 1.6])
        GtObject((t) => _box(x0 - _panShift(t), 0.4), visible: (t) {
          final x = x0 - _panShift(t);
          return x >= 0 && x + 0.2 <= 1;
        }),
    ],
    frameTimesMs: everyMs(400, 5),
    missProb: 0.05,
    jitter: 0.02,
    cameraShift: (t) => Offset(-_panShift(t), 0),
  ),
  Scenario(
    name: '④ 가림 1.5초(사람이 앞을 지나감) · 10FPS',
    objects: [
      GtObject((_) => _box(0.2, 0.3), visible: (t) => t < 2.0 || t > 3.5),
      GtObject((_) => _box(0.6, 0.6)),
    ],
    frameTimesMs: everyMs(100, 6),
    missProb: 0.05,
    jitter: 0.02,
  ),
  Scenario(
    name: '⑤ 두 물체 교차 · 10FPS',
    objects: [
      GtObject((t) => _box(0.1 + 0.15 * t, 0.4)),
      GtObject((t) => _box(0.7 - 0.15 * t, 0.45)),
    ],
    frameTimesMs: everyMs(100, 4),
    missProb: 0.05,
    jitter: 0.02,
  ),
  Scenario(
    name: '⑥ 처리 간격 들쑥날쑥(50~1500ms) · 천천히 이동',
    objects: [
      GtObject((t) => _box(0.1 + 0.02 * t, 0.2)),
      GtObject((t) => _box(0.6, 0.5 + 0.01 * t, 0.25)),
    ],
    frameTimesMs: randomIntervals(50, 1500, 80),
    missProb: 0.1,
    jitter: 0.02,
    falsePosProb: 0.05,
  ),
  Scenario(
    // 카메라 움직임 보정이 틀리는 경우: 확정 트랙이 "걸어가는 사람" 하나뿐이면
    // 그 속도가 새로 나타난 정지 설비에 잘못 들어감 → 그래도 ID가 붙어야 함
    name: '⑦ 사람 혼자 걸어감 + 정지 설비 새로 등장 · 1FPS',
    objects: [
      GtObject((t) => _box(0.05 + 0.04 * t, 0.1, 0.15)),
      GtObject((_) => _box(0.5, 0.6), visible: (t) => t >= 5),
    ],
    frameTimesMs: everyMs(1000, 18),
    missProb: 0.05,
    jitter: 0.02,
  ),
  Scenario(
    // 이미 폰을 돌리는 중에 화면이 시작됨: 확정 트랙이 하나도 없어서
    // 속도 중앙값 보정(4번)은 쓸 수 없고 자이로만 도울 수 있는 상황
    name: '⑧ 빠르게 돌리는 중에 시작(확정 트랙 없음) · 2FPS',
    objects: [
      for (final x0 in [0.1, 0.45, 0.8, 1.15, 1.5, 1.85])
        GtObject((t) => _box(x0 - 0.35 * t, 0.4), visible: (t) {
          final x = x0 - 0.35 * t;
          return x >= 0 && x + 0.2 <= 1;
        }),
    ],
    frameTimesMs: everyMs(500, 6),
    missProb: 0.05,
    jitter: 0.02,
    cameraShift: (t) => Offset(-0.35 * t, 0),
    needsGyro: true,
  ),
  Scenario(
    // 설비 쪽으로 걸어감: 박스가 커지고 가장자리 물체는 바깥으로 밀려남(회전이 아니라 자이로 무관)
    name: '⑨ 설비로 다가가기(줌인) · 5FPS',
    objects: [
      GtObject((t) {
        final s = 1 + 0.75 * t;
        return Rect.fromCenter(
            center: const Offset(0.5, 0.5), width: 0.12 * s, height: 0.12 * s);
      }),
      GtObject((t) {
        final s = 1 + 0.75 * t;
        return Rect.fromCenter(
            center: Offset(0.5 - 0.2 * s, 0.5 - 0.15 * s),
            width: 0.08 * s,
            height: 0.08 * s);
      },
          visible: (t) =>
              0.5 - 0.2 * (1 + 0.75 * t) - 0.04 * (1 + 0.75 * t) >= 0),
    ],
    frameTimesMs: everyMs(200, 4),
    missProb: 0.05,
    jitter: 0.02,
  ),
  Scenario(
    // 배관 밸브처럼 비슷한 설비가 촘촘히 반복 + 패닝: 이웃과 ID가 뒤바뀌기 쉬운 상황
    name: '⑩ 비슷한 설비가 촘촘히 나란히 + 패닝 · 3FPS',
    objects: [
      for (var i = 0; i < 9; i++)
        GtObject(
            (t) => _box(0.05 + 0.13 * i - _panShift(t, vmax: 0.3), 0.45, 0.1),
            visible: (t) {
          final x = 0.05 + 0.13 * i - _panShift(t, vmax: 0.3);
          return x >= 0 && x + 0.1 <= 1;
        }),
    ],
    frameTimesMs: everyMs(333, 4),
    missProb: 0.05,
    jitter: 0.03,
    cameraShift: (t) => Offset(-_panShift(t, vmax: 0.3), 0),
    needsGyro: true,
  ),
  Scenario(
    // 실기기(Z Flip7) 1차 테스트: 물체 1개를 가만히 비춰도 새 ID가 분당 약 65개, 물체 수 1↔2 깜빡임.
    // ML Kit 실제 장면 출력 흉내: 크기가 프레임마다 ±15% 출렁, 같은 물체 일부를 한 번 더 잡음, 가끔 놓침
    name: '⑪ 정지 물체 · 실기기 ML Kit 흉내(크기 떨림·부분 박스·놓침) · 14FPS · 60초',
    objects: [GtObject((_) => _box(0.3, 0.35, 0.35))],
    frameTimesMs: everyMs(70, 60),
    missProb: 0.15,
    jitter: 0.05,
    scaleJitter: 0.15,
    dupProb: 0.25,
    falsePosProb: 0.03,
  ),
  Scenario(
    // 어수선한 실제 장면: ML Kit은 한 번에 최대 5개만 내놓아 어떤 물체가 몇 초씩 빠졌다 돌아옴.
    // 2초 넘게 빠지면 트랙이 지워져 같은 물체가 새 번호를 받던 것
    name: '⑫ 정지 · 어수선한 장면(물체 6개가 번갈아 2~5초씩 빠짐) · 14FPS · 60초',
    objects: [
      for (var o = 0; o < 6; o++)
        GtObject((_) => _box(0.05 + 0.3 * (o % 3), 0.15 + 0.4 * (o ~/ 3), 0.22),
            visible: (t) => (t + 1.7 * o) % (6 + o) > 2 + o * 0.5),
    ],
    frameTimesMs: everyMs(70, 60),
    missProb: 0.1,
    jitter: 0.05,
    scaleJitter: 0.1,
    dupProb: 0.1,
    // 물체 6개가 각각 60초 동안 2~5초씩 6번 넘게 빠짐: 한 물체가 새 번호를 한 번 받는 정도까지
    maxIdSwitches: 1,
  ),
];

void main() {
  final results = <String, (MotMetrics, MotMetrics, MotMetrics?)>{};

  for (final s in scenarios) {
    test(s.name, () async {
      final base = await evaluate(s, (d, _) => BaselineIouTracker(d));
      final now = await evaluate(s, (d, _) => TrackingDetector(d));
      // 카메라가 회전하는 시나리오만: 화각 25% 오차·잡음 섞인 가짜 자이로로 보정
      final gyro = s.cameraShift == null
          ? null
          : await evaluate(s, (d, m) => TrackingDetector(d, motion: m),
              gyro: true);
      results[s.name] = (base, now, gyro);
      // ignore: avoid_print
      print('${s.name}\n  이전  : $base\n  새것  : $now'
          '${gyro == null ? '' : '\n  +자이로: $gyro'}');

      // 새 추적기 합격 기준: ID 전환 없음, 오탐에 ID 거의 안 붙음,
      // ID 재현율(올바른 ID로 추적된 비율)이 이전보다 나쁘지 않음.
      // 자이로 필수 시나리오는 자이로 없을 때 "이전보다 나음"만 요구
      if (!s.needsGyro) {
        expect(now.idSwitches, lessThanOrEqualTo(s.maxIdSwitches),
            reason: 'ID 전환');
      }
      expect(now.falseIds, lessThanOrEqualTo(1), reason: '오탐 ID');
      expect(now.idSwitches, lessThanOrEqualTo(base.idSwitches));
      expect(now.idRecall, greaterThanOrEqualTo(math.min(0.8, base.idRecall)),
          reason: 'ID 재현율');
      // 자이로를 켜면 같은 기준 + 끈 것보다 나빠지지 않음
      if (gyro != null) {
        expect(gyro.idSwitches, 0, reason: '자이로 ID 전환');
        expect(gyro.falseIds, lessThanOrEqualTo(1), reason: '자이로 오탐 ID');
        expect(gyro.idRecall, greaterThanOrEqualTo(now.idRecall - 0.02),
            reason: '자이로 ID 재현율');
        if (s.needsGyro) {
          expect(gyro.idRecall, greaterThanOrEqualTo(0.5),
              reason: '자이로 필수 시나리오 ID 재현율');
        }
      }
    });
  }

  tearDownAll(() {
    String pct(MotMetrics? m) =>
        m == null ? '  -' : '${(m.idRecall * 100).round()}%'.padLeft(4);
    // ignore: avoid_print
    print('\n=== 요약: IDSW 이전→새것 | ID재현율 이전 / 새것 / +자이로 ===\n${[
      for (final e in results.entries)
        '${e.key}: ${e.value.$1.idSwitches}→${e.value.$2.idSwitches} | '
            '${pct(e.value.$1)} / ${pct(e.value.$2)} / ${pct(e.value.$3)}'
    ].join('\n')}');
  });
}
