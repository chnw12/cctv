import 'dart:math' as math;
import 'dart:ui';
import '../analysis/hazard.dart';
import '../ui/box_painter.dart';

/// 1€ 필터(Casiez 2012): 손끝이 멈춰 있을 땐 떨림을 강하게 누르고, 빨리 움직이면 덜 눌러 늦지 않게.
/// AR·VR 손 추적 포인터에서 흔히 씀. 값은 화면 비율(0..1), 시각은 초
class OneEuroFilter {
  OneEuroFilter({this.minCutoff = 1.0, this.beta = 2.0, this.dCutoff = 1.0});
  final double minCutoff, beta, dCutoff;
  double? _x, _dx, _t;

  static double _alpha(double cutoff, double dt) {
    final tau = 1 / (2 * math.pi * cutoff);
    return 1 / (1 + tau / dt);
  }

  double filter(double x, double t) {
    final px = _x, pt = _t;
    _t = t;
    if (px == null || pt == null || t <= pt) {
      _dx = 0;
      return _x = x;
    }
    final dt = t - pt;
    final dx = (x - px) / dt;
    final edx = _dx = _dx! + _alpha(dCutoff, dt) * (dx - _dx!);
    final cutoff = minCutoff + beta * edx.abs();
    return _x = px + _alpha(cutoff, dt) * (x - px);
  }

  void reset() => _x = _dx = _t = null;
}

/// 손끝이 지금 무엇 위에 있나
enum HandTarget { none, hazard, ignore, done }

sealed class HandEvent {
  const HandEvent();
}

/// 위험 박스 위에 [HandPointer.selectMs] 머무름 → 그 위험의 [무시] [완료] 버튼 띄우기
class SelectHazard extends HandEvent {
  const SelectHazard(this.index);
  final int index;
}

/// 버튼 위에 [HandPointer.pressMs] 머무름 → 누름
class PressAction extends HandEvent {
  const PressAction(this.action);
  final HazardStatus action;
}

/// 화면 속 검지 끝으로 위험 박스·버튼 "누르기"(AR 1단계). 카메라 하나로는 깊이를 정확히 못 재므로
/// "닿음"은 머무르기로 판정: 박스 위 0.3초 → 버튼 표시, 버튼 위 1초 → 선택(진행 원 표시).
/// 손을 떼거나 다른 데로 가면 취소, 폰이 빠르게 움직이는 중엔 진행 안 함, 누른 직후 잠깐 쉼(연속 오작동 방지).
/// 시각은 프레임 시각(ms)이라 테스트에서 그대로 재현됨
class HandPointer {
  static const selectMs = 300, pressMs = 1000, lostMs = 500, cooldownMs = 800;

  /// 버튼 판정 여유(장갑·손끝 흔들림)
  static const slop = 8.0;

  final _fx = OneEuroFilter(), _fy = OneEuroFilter();

  /// 부드럽게 한 검지 끝(화면 px). 손이 없으면 null
  Offset? tip;

  /// 지금 대상과 진행(0..1): 박스 위면 선택까지, 버튼 위면 누름까지
  HandTarget target = HandTarget.none;
  double progress = 0;

  int? _lastSeen, _targetSince, _cooldownUntil;
  int? _hover; // 머무르는 위험 번호

  void reset() {
    tip = null;
    _fx.reset();
    _fy.reset();
    _lastSeen = null;
    _clear();
  }

  void _clear() {
    target = HandTarget.none;
    progress = 0;
    _targetSince = null;
    _hover = null;
  }

  /// [tipNorm]: 검지 끝(0..1, 없으면 null), [hazards]: 처리 안 된 위험의 화면 사각형,
  /// [selected]: 버튼을 띄운 위험, [layout]: 그 버튼 자리, [moving]: 폰이 빠르게 도는 중
  HandEvent? update(int ms, Offset? tipNorm, Size view,
      {required Map<int, Rect> hazards,
      int? selected,
      HazardActionLayout? layout,
      bool moving = false}) {
    if (tipNorm == null) {
      // 한두 프레임 놓친 건 기다림(손 인식이 잠깐 끊김)
      if (_lastSeen == null || ms - _lastSeen! > lostMs) reset();
      return null;
    }
    _lastSeen = ms;
    final t = ms / 1000;
    final p = tip = Offset(_fx.filter(tipNorm.dx, t) * view.width,
        _fy.filter(tipNorm.dy, t) * view.height);
    if (moving || (_cooldownUntil != null && ms < _cooldownUntil!)) {
      _clear();
      return null;
    }

    // 1) 버튼 위: 누름 진행
    if (selected != null && layout != null) {
      final on = layout.ignore.inflate(slop).contains(p)
          ? HandTarget.ignore
          : layout.done.inflate(slop).contains(p)
              ? HandTarget.done
              : HandTarget.none;
      if (on != HandTarget.none) {
        if (on != target) {
          _clear();
          target = on;
          _targetSince = ms;
        }
        progress = ((ms - _targetSince!) / pressMs).clamp(0.0, 1.0);
        if (progress < 1) return null;
        _clear();
        _cooldownUntil = ms + cooldownMs;
        return PressAction(on == HandTarget.ignore
            ? HazardStatus.ignored
            : HazardStatus.resolved);
      }
    }

    // 2) 위험 박스 위: 선택 진행(이미 버튼을 띄운 위험은 제외)
    final h = _hit(hazards, p);
    if (h == null || h == selected) {
      _clear();
      return null;
    }
    if (h != _hover || target != HandTarget.hazard) {
      _clear();
      _hover = h;
      target = HandTarget.hazard;
      _targetSince = ms;
    }
    progress = ((ms - _targetSince!) / selectMs).clamp(0.0, 1.0);
    if (progress < 1) return null;
    _clear();
    return SelectHazard(h);
  }

  /// 겹치면 작은(안쪽) 박스
  static int? _hit(Map<int, Rect> hazards, Offset p) {
    int? best;
    var area = double.infinity;
    hazards.forEach((i, r) {
      if (!r.inflate(slop).contains(p)) return;
      final a = r.width * r.height;
      if (a < area) {
        area = a;
        best = i;
      }
    });
    return best;
  }
}
