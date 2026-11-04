import 'dart:ui';
import 'package:facility_camera/analysis/hazard.dart';
import 'package:facility_camera/camera/auto_save_guard.dart';
import 'package:flutter_test/flutter_test.dart';

HazardReport _r(List<String> types) => HazardReport.fromJson({
      'summary': '',
      'hazards': [
        for (final t in types)
          {'type': t, 'description': '', 'severity': 'high', 'action': ''}
      ],
    }, 0, const Size(1, 1));

void main() {
  test('같은 위험은 1분 안에 다시 저장 안 함, 새 위험이 섞이면 저장', () {
    var now = DateTime(2026, 10, 31, 12);
    final g = AutoSaveGuard(now: () => now);
    expect(g.shouldSave(_r(['바닥 누수'])), isTrue);
    now = now.add(const Duration(seconds: 20));
    expect(g.shouldSave(_r(['바닥누수'])), isFalse); // 띄어쓰기만 다름
    expect(g.shouldSave(_r(['바닥 누수', '분전반 열림'])), isTrue); // 새 위험 포함
    now = now.add(const Duration(seconds: 70));
    expect(g.shouldSave(_r(['바닥 누수'])), isTrue); // 1분 지남
    expect(g.shouldSave(_r([])), isFalse); // 위험 없음은 저장 대상 아님
  });
}
