import 'dart:math' as math;
import 'package:facility_camera/motion/camera_motion.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('부호: 왼쪽으로 돌리면(ω_y>0) 물체는 오른쪽(+x), 위로 들면(ω_x>0) 아래(+y)', () {
    final m = GyroCameraMotion(fovX: 1.0, fovY: 1.0);
    for (var t = 20; t <= 1000; t += 20) {
      m.addSample(t, 0.2, 0.5); // ω_x = 0.2, ω_y = 0.5 rad/s
    }
    final s = m.shiftBetween(0, 1000);
    expect(s.dx, closeTo(0.5, 0.01)); // 0.5 rad / 화각 1 rad
    expect(s.dy, closeTo(0.2, 0.01));
  });

  test('2배 줌이면 같은 회전에 화면은 2배 이동', () {
    final m = GyroCameraMotion(fovX: 1.0, fovY: 1.0)..zoom = 2;
    for (var t = 20; t <= 1000; t += 20) {
      m.addSample(t, 0, 0.5);
    }
    expect(m.shiftBetween(0, 1000).dx, closeTo(1.0, 0.02));
    expect(m.radToX, 1.0); // 학습 기준(1배)은 그대로
  });

  test('센서 값이 프레임보다 늦게 와도 빠뜨리지 않음(도착한 데까지만 적분, 나머지는 다음에)', () {
    final m = GyroCameraMotion(fovX: 1.0, fovY: 1.0);
    var total = 0.0, oldWay = 0.0;
    var cursor = 0;
    // 프레임은 100ms마다. 그 구간의 센서 값(1rad/s, 20ms 간격)은 프레임을 처리한 "뒤에" 도착
    for (var frame = 100; frame <= 1000; frame += 100) {
      final (s, next) = m.shiftSince(cursor, frame);
      total += s.dx;
      cursor = next;
      oldWay += m.shiftBetween(frame - 100, frame).dx; // 프레임 시각까지 자르던 방식
      for (var t = frame - 80; t <= frame; t += 20) {
        m.addSample(t, 0, 1.0); // 늦게 도착
      }
    }
    // 새 방식: 마지막 프레임 전까지 도착한 900ms 분량을 빠짐없이 ≈ 0.9rad
    expect(total, closeTo(0.9, 0.03));
    // 이전 방식: 늦게 온 값을 다음 구간에서 버려서 거의 0
    expect(oldWay, lessThan(0.05));
  });

  test('영점 오차: 들고 가만히 있을 때(손떨림+영점 0.01rad/s) 학습해서 표시가 밀리지 않음', () {
    final m = GyroCameraMotion(fovX: 1.0, fovY: 1.0);
    var t = 0;
    // 30초 정지: 손떨림 ±0.04 번갈아 + 영점 0.01
    for (; t <= 30000; t += 20) {
      final tremor = (t ~/ 20).isEven ? 0.04 : -0.04;
      m.addSample(t, -0.01 + tremor, 0.01 + tremor);
    }
    expect(m.bias.dy, closeTo(0.01, 0.002));
    expect(m.bias.dx, closeTo(-0.01, 0.002));
    // 보정 없으면 10초에 0.1(화면 10%) 밀림(아래 3초 구간이면 0.03) → 보정 후 거의 0
    for (var i = 0; i < 500; i++) {
      final tt = t + i * 20;
      final tremor = i.isEven ? 0.04 : -0.04;
      m.addSample(tt, -0.01 + tremor, 0.01 + tremor);
    }
    expect(m.shiftBetween(t + 7000, t + 9980).dx.abs(), lessThan(0.004));
  });

  test('영점 학습이 실제 회전을 먹지 않음(돌리는 중엔 학습 안 함, 영점 한도 ±0.02)', () {
    final m = GyroCameraMotion(fovX: 1.0, fovY: 1.0);
    // 20초 동안 계속 0.5rad/s로 돌림 → 정지가 아니므로 학습 안 함
    for (var t = 0; t <= 20000; t += 20) {
      m.addSample(t, 0, 0.5);
    }
    expect(m.bias, Offset.zero);
    expect(m.shiftBetween(19000, 20000).dx, closeTo(0.5, 0.01));
    // 아주 느린 회전(0.015rad/s)이 오래 이어져도 영점 한도를 넘지 않음
    final slow = GyroCameraMotion(fovX: 1.0, fovY: 1.0);
    for (var t = 0; t <= 120000; t += 20) {
      slow.addSample(t, 0, 0.05);
    }
    expect(slow.bias.dx, 0);
    expect(slow.bias.dy, lessThanOrEqualTo(GyroCameraMotion.biasMax));
  });

  test('구간 적분: 요청한 시간 구간만 더함', () {
    final m = GyroCameraMotion(fovX: 1.0, fovY: 1.0);
    for (var t = 20; t <= 2000; t += 20) {
      m.addSample(t, 0, t <= 1000 ? 1.0 : 0.0); // 처음 1초만 회전
    }
    expect(m.shiftBetween(500, 1500).dx, closeTo(0.5, 0.02));
    expect(m.shiftBetween(1000, 2000).dx, closeTo(0, 0.02));
    expect(m.shiftBetween(1000, 1000), Offset.zero);
  });

  test('화각 온라인 보정: 실제 화각이 25% 넓어도 잔차로 배율이 수렴', () {
    final m = GyroCameraMotion(); // 가정 화각 0.75 rad
    const trueK = 1 / (GyroCameraMotion.defaultFovX * 1.25);
    for (var i = 0; i < 30; i++) {
      const rot = 0.1; // 프레임마다 0.1 rad
      final used = Offset(rot * m.radToX, 0);
      const real = Offset(rot * trueK, 0);
      m.calibrate(used, real - used); // 잔차 = 실제 − 예측
    }
    expect(m.radToX, closeTo(trueK, trueK * 0.02));
  });

  test('자이로는 도는데 영상은 그대로(불일치)면 화각을 학습하지 않음', () {
    final m = GyroCameraMotion();
    final k0 = m.radToX;
    for (var i = 0; i < 30; i++) {
      final used = Offset(0.1 * m.radToX, 0);
      m.calibrate(used, -used); // 실제 이동 0 → 잔차 = −예측 (비율 −1)
    }
    expect(m.radToX, k0);
  });

  test('작은 이동에서는 보정하지 않음(잡음에 흔들리지 않게)', () {
    final m = GyroCameraMotion();
    final k0 = m.radToX;
    m.calibrate(const Offset(0.005, 0), const Offset(0.004, 0));
    expect(m.radToX, k0);
  });

  test('렌즈 값 → 화각: Z Flip7 메인(5.4mm, 8.16×6.12mm 센서) 720p 세로 = 46°×74°', () {
    const deg = 180 / math.pi;
    final fov = LensFov.portrait(
        focalMm: 5.4,
        sensorWMm: 8.16,
        sensorHMm: 6.12,
        streamW: 1280,
        streamH: 720)!;
    expect(fov.width * deg, closeTo(46.1, 0.2)); // 16:9라 센서 짧은 변(4.59mm)만 씀
    expect(fov.height * deg, closeTo(74.1, 0.2));
    // 4:3 영상이면 센서 전체, 센서가 안 돌아가 있으면 가로·세로 그대로
    final full = LensFov.portrait(
        focalMm: 5.4,
        sensorWMm: 8.16,
        sensorHMm: 6.12,
        streamW: 1440,
        streamH: 1080,
        rotated: false)!;
    expect(full.width * deg, closeTo(74.1, 0.2));
    expect(full.height * deg, closeTo(59.1, 0.2));
    expect(
        LensFov.portrait(
            focalMm: 0,
            sensorWMm: 8,
            sensorHMm: 6,
            streamW: 1280,
            streamH: 720),
        isNull);
  });

  test('렌즈 값을 알면 그 값에서 시작하고, 보정은 ±20% 안에서 천천히', () {
    final m = GyroCameraMotion()..useLensFov(0.8, 1.3);
    expect(m.radToX, 1 / 0.8);
    expect(m.lensFovX, 0.8);
    // 잔차가 계속 "덜 옮김"(비율 1)이라고 해도 렌즈 값의 1.2배에서 멈춤
    for (var i = 0; i < 200; i++) {
      final used = Offset(0.1 * m.radToX, 0);
      m.calibrate(used, used);
    }
    expect(m.radToX, closeTo(1.2 / 0.8, 1e-9));
    // 렌즈 값 없을 때보다 한 번에 움직이는 양이 작음(잡음 때문에 출렁이지 않게)
    final a = GyroCameraMotion()..useLensFov(0.8, 1.3);
    final b = GyroCameraMotion(fovX: 0.8, fovY: 1.3);
    for (final g in [a, b]) {
      g.calibrate(Offset(0.1 * g.radToX, 0), Offset(0.05 * g.radToX, 0));
    }
    expect(a.radToX / (1 / 0.8) - 1, closeTo(0.025, 1e-9)); // 0.05 × 비율 0.5
    expect(b.radToX / (1 / 0.8) - 1, closeTo(0.1, 1e-9)); // 0.2 × 0.5
    expect(b.lensFovX, isNull);
  });
}
