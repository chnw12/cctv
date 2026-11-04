import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:sensors_plus/sensors_plus.dart';

/// 카메라(폰) 자체가 움직여서 생기는 화면 이동량.
/// 자율주행이 IMU·오도메트리로 자차 움직임(ego-motion)을 빼고 주변 물체를 추적하듯,
/// 추적기는 예측 단계에서 모든 트랙을 이 만큼 옮깁니다.
abstract class CameraMotion {
  /// t0~t1(ms) 동안 카메라 회전 때문에 화면 속 "정지한" 물체가 움직인 양(0..1 정규화)
  Offset shiftBetween(int t0Ms, int t1Ms);

  /// fromMs부터 "실제로 도착한 센서 값"까지만 적분: (이동량, 다음 시작 시각).
  /// 센서 값은 영상 프레임보다 조금 늦게 도착하기도 해서, 프레임 시각까지 적분하면
  /// 늦게 온 값이 영영 빠짐(테스트에서 발견) → 반환된 시각부터 다음에 이어서 셈
  (Offset, int) shiftSince(int fromMs, int toMs);

  /// 예측에 쓴 이동량과, 실제로 정지 물체들이 예측에서 벗어난 양(잔차)으로 배율 보정
  void calibrate(Offset usedShift, Offset residual) {}

  /// 지금 폰이 도는 빠르기(rad/s). 모르면 0
  double get angularSpeed => 0;

  Future<void> start();
  Future<void> stop();
}

/// 자이로스코프 기반. 화면이 세로 고정이라 기기 축 = 화면 축:
/// - 기기 Y축 회전(좌우로 돌리기) ω_y > 0 → 카메라가 왼쪽을 봄 → 화면 속 물체는 오른쪽(+x)
/// - 기기 X축 회전(위아래로 기울이기) ω_x > 0 → 카메라가 위를 봄 → 화면 속 물체는 아래(+y)
/// 이동량(화면 비율) ≈ 회전각(rad) / 화각(rad). 화각은 렌즈 값([useLensFov])을 알면 그 값,
/// 모르면 보통 폰 값에서 시작해 [calibrate]로 실제 관측에 맞춰 갑니다(온라인 보정).
/// Z축(롤) 회전은 아직 반영하지 않습니다.
class GyroCameraMotion implements CameraMotion {
  GyroCameraMotion({double? fovX, double? fovY})
      : _kx = 1 / (fovX ?? defaultFovX),
        _ky = 1 / (fovY ?? defaultFovY);

  /// 세로 화면 기준 16:9(720x1280) 화각 추정: 가로 ≈ 43°, 세로 ≈ 66°
  static const defaultFovX = 0.75, defaultFovY = 1.15;

  /// 배율(1/화각) 허용 범위: 광각 ~115°(0.5) ~ 줌 ~15°(4.0)
  static const _kMin = 0.5, _kMax = 4.0;
  static const _calibGain = 0.2;

  /// 렌즈 값을 알 때: 그 값의 ±20% 안에서만, 천천히 보정
  static const lensRange = 1.2, _lensGain = 0.05;

  double _kx, _ky;
  double? _lensKx, _lensKy;
  final _samples = <_Gyro>[];
  StreamSubscription<GyroscopeEvent>? _sub;

  /// 1배 기준 배율(1/화각). 화각 학습은 이 값에 쌓임
  double get radToX => _kx;
  double get radToY => _ky;

  /// 렌즈 값으로 계산한 가로 화각(rad). 모르면 null
  double? get lensFovX => _lensKx == null ? null : 1 / _lensKx!;

  /// 렌즈 값(초점거리·센서 크기, [LensFov])으로 계산한 화각에서 시작. 온라인 보정은 남은 차이
  /// (손떨림 보정 크롭 등)만 이 값 근처에서 천천히 다듬음 → 실기기(Z Flip7, 렌즈 값 46°)에서
  /// 탐지 박스 흔들림 때문에 학습 화각이 38~53°로 출렁이던 것을 줄임
  void useLensFov(double fovX, double fovY) {
    _kx = _lensKx = 1 / fovX;
    _ky = _lensKy = 1 / fovY;
  }

  /// 카메라 줌 배율. 2배 줌이면 화각이 절반 → 같은 회전에 화면이 2배 움직임
  double zoom = 1;

  /// 정지 중 추정한 자이로 영점 오차(ω_x, ω_y, rad/s). 받은 값에서 빼고 씀
  Offset get bias => Offset(_bx, _by);
  double _bx = 0, _by = 0;

  // 영점 학습용 1초 창: 합계·개수·가장 큰 흔들림
  int? _winStart;
  double _sumX = 0, _sumY = 0, _peak = 0;
  int _n = 0;

  /// 손떨림만 있는 "정지"로 볼 최대 각속도, 창 평균이 영점에서 이만큼 안이면 학습
  static const stillPeak = 0.08, biasMaxStep = 0.02, biasMax = 0.02;
  static const _biasGain = 0.1;

  /// 최근 각속도(ω_x, ω_y, rad/s, 영점 보정 후). 로그·화면 표시용
  @override
  double get angularSpeed => lastRate.distance;

  Offset get lastRate => _samples.isEmpty
      ? Offset.zero
      : Offset(_samples.last.wx, _samples.last.wy);

  @override
  Future<void> start() async {
    if (_sub != null) return;
    // 플러그인이 샘플링 주기 설정을 기다리지 않고(unawaited) 호출해서, 실패하면 스트림 onError가 아닌
    // "잡히지 않은 예외"로 새어 나옴(테스트에서 발견). 자이로 없는 기기·센서 오류도 같은 길 →
    // 이 영역 안에서 생긴 오류는 모두 삼키고 이동량 0(박스 정렬 보정만)으로 동작
    runZonedGuarded(() {
      _sub = gyroscopeEventStream(samplingPeriod: SensorInterval.gameInterval)
          .listen(
              (e) => addSample(e.timestamp.millisecondsSinceEpoch, e.x, e.y),
              onError: (_) {});
    }, (e, _) => debugPrint('자이로 사용 불가, 보정 없이 진행: $e'));
  }

  /// 원본 샘플을 받을 곳(분석 로그 기록용, 영점 보정 전 값)
  void Function(int ms, double wx, double wy)? onSample;

  /// 테스트에서 직접 넣을 수 있게 공개
  void addSample(int ms, double wx, double wy) {
    onSample?.call(ms, wx, wy);
    _learnBias(ms, wx, wy);
    _samples.add(_Gyro(ms, wx - _bx, wy - _by));
    while (_samples.isNotEmpty && ms - _samples.first.ms > 3000) {
      _samples.removeAt(0);
    }
  }

  /// 정지 구간 영점 보정(자율주행 IMU의 ZUPT: 멈춰 있을 때 나오는 각속도는 센서 오차).
  /// 영점이 0.005rad/s만 틀려도 1분이면 0.3rad → 자이로로 붙여 둔 위험 표시가 화면 40% 밀림.
  /// 1초 창 동안 손떨림 수준만 있고 평균이 영점 근처면 그 평균 쪽으로 조금씩(10%) 옮김.
  /// 아주 느린 실제 회전(1°/s 안팎)도 일부 흡수될 수 있어 영점은 ±0.02rad/s로 제한
  void _learnBias(int ms, double wx, double wy) {
    final start = _winStart;
    if (start == null || ms < start) {
      _resetWindow(ms);
    } else if (ms - start >= 1000 && _n > 0) {
      final mx = _sumX / _n, my = _sumY / _n;
      if (_peak < stillPeak &&
          (mx - _bx).abs() < biasMaxStep &&
          (my - _by).abs() < biasMaxStep) {
        _bx = (_bx + _biasGain * (mx - _bx)).clamp(-biasMax, biasMax);
        _by = (_by + _biasGain * (my - _by)).clamp(-biasMax, biasMax);
      }
      _resetWindow(ms);
    }
    _sumX += wx;
    _sumY += wy;
    _n++;
    final p = math.max((wx - _bx).abs(), (wy - _by).abs());
    if (p > _peak) _peak = p;
  }

  void _resetWindow(int ms) {
    _winStart = ms;
    _sumX = _sumY = _peak = 0;
    _n = 0;
  }

  @override
  Offset shiftBetween(int t0Ms, int t1Ms) {
    if (t1Ms <= t0Ms || _samples.isEmpty) return Offset.zero;
    // 각 샘플을 "직전 샘플 시각 ~ 이 샘플 시각" 구간의 각속도로 보고 [t0, t1]과 겹치는 만큼 적분
    var rx = 0.0, ry = 0.0;
    for (var i = 0; i < _samples.length; i++) {
      final s = _samples[i];
      final from = i == 0 ? s.ms - 20 : _samples[i - 1].ms;
      final a = from > t0Ms ? from : t0Ms;
      final b = s.ms < t1Ms ? s.ms : t1Ms;
      if (b <= a) continue;
      final dt = (b - a) / 1000;
      rx += s.wx * dt;
      ry += s.wy * dt;
    }
    return Offset(ry * _kx * zoom, rx * _ky * zoom);
  }

  @override
  (Offset, int) shiftSince(int fromMs, int toMs) {
    if (_samples.isEmpty) return (Offset.zero, fromMs);
    final end = toMs < _samples.last.ms ? toMs : _samples.last.ms;
    if (end <= fromMs) return (Offset.zero, fromMs);
    return (shiftBetween(fromMs, end), end);
  }

  @override
  void calibrate(Offset usedShift, Offset residual) {
    // 잔차가 이동 방향과 같으면 배율이 작은 것(덜 옮김) → 키움, 반대면 줄임.
    // 비율이 -0.5~+1(화각 오차 약 ±50%)을 벗어나면 배율 문제가 아니라 자이로와 영상이
    // 안 맞는 것(물체가 움직임·외부 카메라 등)으로 보고 학습하지 않음 = 센서 융합의 이상치 게이팅.
    // 에뮬레이터에서 영상은 정지·자이로만 0.5rad/s로 주자 화각이 43°→69°로 잘못 학습된 것을 막음
    // 렌즈 값을 알면 그 근처(±20%)에서만, 4배 천천히
    double update(double k, double used, double res, double? lens) {
      if (used.abs() <= 0.02) return k;
      final ratio = res / used;
      if (ratio < -0.5 || ratio > 1.0) return k;
      return lens == null
          ? (k * (1 + _calibGain * ratio)).clamp(_kMin, _kMax)
          : (k * (1 + _lensGain * ratio))
              .clamp(lens / lensRange, lens * lensRange);
    }

    _kx = update(_kx, usedShift.dx, residual.dx, _lensKx);
    _ky = update(_ky, usedShift.dy, residual.dy, _lensKy);
  }

  @override
  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    _samples.clear();
  }
}

/// 카메라 내부 파라미터(초점거리·센서 크기)로 계산한 화각.
/// 자율주행 카메라가 공장 보정값(intrinsics)으로 픽셀 ↔ 각도를 바꾸듯, 자이로 회전각을
/// 화면 이동량으로 바꾸는 기준값으로 씀.
class LensFov {
  /// 세로 고정 화면 기준 (가로, 세로) 화각(rad). [streamW]x[streamH]는 센서 방향(가로형) 영상 크기.
  /// 영상이 센서보다 가로로 길면(16:9 영상, 4:3 센서) 위아래가 잘리고, 반대면 좌우가 잘림.
  /// [rotated]: 센서가 90/270° 돌아가 있음(폰 후면 카메라 대부분) → 센서 긴 변이 화면 세로
  static Size? portrait({
    required double focalMm,
    required double sensorWMm,
    required double sensorHMm,
    required double streamW,
    required double streamH,
    bool rotated = true,
  }) {
    if (focalMm <= 0 ||
        sensorWMm <= 0 ||
        sensorHMm <= 0 ||
        streamW <= 0 ||
        streamH <= 0) {
      return null;
    }
    final aspect = streamW / streamH;
    final wide = aspect >= sensorWMm / sensorHMm;
    final w = wide ? sensorWMm : sensorHMm * aspect;
    final h = wide ? sensorWMm / aspect : sensorHMm;
    double fov(double mm) => 2 * math.atan(mm / 2 / focalMm);
    return rotated ? Size(fov(h), fov(w)) : Size(fov(w), fov(h));
  }
}

class _Gyro {
  _Gyro(this.ms, this.wx, this.wy);
  final int ms;
  final double wx, wy;
}
