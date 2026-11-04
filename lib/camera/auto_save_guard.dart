import '../analysis/hazard.dart';

/// 자동 점검이 같은 위험을 짧은 시간에 여러 번 저장하지 않게.
/// 폰을 조금씩 움직이면 같은 물체가 새 ID로 다시 잡혀 자동 점검이 반복되기 쉬움 →
/// 이번 결과의 위험 종류가 모두 최근(window 안)에 저장된 것이면 건너뜀
class AutoSaveGuard {
  AutoSaveGuard(
      {this.window = const Duration(seconds: 60), DateTime Function()? now})
      : _now = now ?? DateTime.now;

  final Duration window;
  final DateTime Function() _now;
  final _lastSaved = <String, DateTime>{};

  /// 저장해야 하면 true(그리고 저장한 것으로 기록), 모두 최근에 저장한 위험이면 false
  bool shouldSave(HazardReport r) {
    if (r.hazards.isEmpty) return false;
    final t = _now();
    final kinds = r.hazards.map((h) => _key(h.type)).toSet();
    final hasNew = kinds.any(
        (k) => _lastSaved[k] == null || t.difference(_lastSaved[k]!) > window);
    if (hasNew) {
      for (final k in kinds) {
        _lastSaved[k] = t;
      }
    }
    return hasNew;
  }

  /// 띄어쓰기·대소문자 차이는 같은 위험으로("바닥 누수" = "바닥누수")
  static String _key(String type) => type.replaceAll(' ', '').toLowerCase();
}
