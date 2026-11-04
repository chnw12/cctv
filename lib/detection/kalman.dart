import 'dart:math' as math;
import 'dart:ui';

/// 1차원 등속(constant velocity) 칼만 필터: 상태 = (위치, 속도).
/// SORT/DeepSORT의 8차원 박스 필터는 F·H·Q·R이 좌표마다 독립(블록 대각)이라
/// 좌표마다 이 필터를 하나씩 두는 것과 수학적으로 같습니다.
class Kalman1D {
  Kalman1D(double z, {required double r, required double velVar})
      : x = z,
        p00 = r,
        p11 = velVar;

  double x; // 위치
  double v = 0; // 속도(단위/초)
  double p00, p01 = 0, p11; // 공분산(대칭)

  /// dt초 앞으로 예측. q = 가속도 백색잡음 세기(단위²/초³)
  void predict(double dt, double q) {
    if (dt <= 0) return;
    x += v * dt;
    // P = F P Fᵀ + Q,  F = [[1, dt], [0, 1]],  Q = q·[[dt³/3, dt²/2], [dt²/2, dt]]
    final n00 = p00 + 2 * dt * p01 + dt * dt * p11 + q * dt * dt * dt / 3;
    final n01 = p01 + dt * p11 + q * dt * dt / 2;
    final n11 = p11 + q * dt;
    p00 = n00;
    p01 = n01;
    p11 = n11;
  }

  /// 위치 측정 z(분산 r)로 보정
  void update(double z, double r) {
    final s = p00 + r;
    final k0 = p00 / s, k1 = p01 / s;
    final y = z - x;
    x += k0 * y;
    v += k1 * y;
    final n00 = (1 - k0) * p00;
    final n01 = (1 - k0) * p01;
    final n11 = p11 - k1 * p01;
    p00 = n00;
    p01 = n01;
    p11 = n11;
  }
}

/// 박스(중심 x·y, 너비, 높이)를 좌표별 칼만 필터로 추적. 좌표는 0..1 정규화.
/// 잡음 크기는 DeepSORT처럼 박스 크기에 비례(작은 물체는 더 정밀하게).
class BoxKalman {
  /// velocity: 처음 속도 추정(카메라 움직임 보정용, 화면/초). 모르면 0
  BoxKalman(Rect box, {Offset velocity = Offset.zero})
      : _cx = Kalman1D(box.center.dx, r: _r(box), velVar: posVelVar)
          ..v = velocity.dx,
        _cy = Kalman1D(box.center.dy, r: _r(box), velVar: posVelVar)
          ..v = velocity.dy,
        _w = Kalman1D(box.width, r: _r(box), velVar: sizeVelVar),
        _h = Kalman1D(box.height, r: _r(box), velVar: sizeVelVar);

  /// 처음엔 속도를 모르므로 크게(화면 1개/초 수준)
  static const posVelVar = 1.0;
  static const sizeVelVar = 0.01;

  /// 손에 든 폰의 흔들림·패닝 정도 가속도. 클수록 측정을 더 믿고 빨리 따라감
  static const posAccel = 0.25;
  static const sizeAccel = 0.01;

  /// 측정 표준편차 = 박스 크기의 5% (DeepSORT std_weight_position = 1/20)
  static double _r(Rect b) {
    final s = 0.05 * (b.width + b.height) / 2;
    return math.max(s * s, 1e-6);
  }

  final Kalman1D _cx, _cy, _w, _h;

  /// 중심 이동 속도(화면/초)
  Offset get velocity => Offset(_cx.v, _cy.v);

  Rect get box {
    final w = math.max(_w.x, 1e-3), h = math.max(_h.x, 1e-3);
    return Rect.fromCenter(center: Offset(_cx.x, _cy.x), width: w, height: h);
  }

  void predict(double dt) {
    _cx.predict(dt, posAccel);
    _cy.predict(dt, posAccel);
    _w.predict(dt, sizeAccel);
    _h.predict(dt, sizeAccel);
  }

  /// 카메라 움직임만큼 위치를 옮김(칼만의 제어 입력 u). 자이로 배율 오차를 감안해
  /// 이동량의 20%를 위치 불확실성에 더해 다음 측정을 더 믿게 합니다.
  void shift(Offset d) {
    _cx
      ..x += d.dx
      ..p00 += 0.04 * d.dx * d.dx;
    _cy
      ..x += d.dy
      ..p00 += 0.04 * d.dy * d.dy;
  }

  /// 못 찾은 프레임마다 속도를 줄임: 점검 장면의 설비는 대부분 정지(움직임은 카메라 쪽, 자이로·정렬로 따로 보정)라
  /// 떨리는 박스에서 생긴 가짜 속도로 예측이 흘러가 버리면 다시 나타났을 때 못 이음
  void dampVelocity(double f) {
    _cx.v *= f;
    _cy.v *= f;
    _w.v *= f;
    _h.v *= f;
  }

  void update(Rect m) {
    final r = _r(m);
    _cx.update(m.center.dx, r);
    _cy.update(m.center.dy, r);
    _w.update(m.width, r);
    _h.update(m.height, r);
  }
}
