import 'dart:io';
import 'dart:ui';
import 'package:facility_camera/analysis/fake_hazard_analyzer.dart';
import 'package:facility_camera/analysis/hazard.dart';
import 'package:facility_camera/analysis/hazard_rules.dart';
import 'package:facility_camera/camera/auto_save_guard.dart';
import 'package:flutter_test/flutter_test.dart';

/// 위험 판단 규칙표: AI는 종류만 고르고 등급은 앱이 정함(강사 피드백 "LLM 의존도 완화·평가 기준 보완")
void main() {
  Map<String, dynamic> hz(String category, {String? severity, String? type}) =>
      {
        'category': category,
        'type': type ?? category,
        'description': '근거',
        'action': '조치',
        if (severity != null) 'severity': severity,
      };
  HazardReport ai(List<Map<String, dynamic>> hs) => HazardReport.fromAi(
      {'summary': 's', 'hazards': hs}, 0, const Size(1, 1));

  test('규칙표: 종류 이름이 겹치지 않고, 기타를 뺀 모든 종류에 관련 기준이 있음', () {
    expect(HazardRules.keys.toSet(), hasLength(HazardRules.all.length));
    expect(HazardRules.all.map((r) => r.label).toSet(),
        hasLength(HazardRules.all.length));
    for (final r in HazardRules.all) {
      expect(r.definition, isNotEmpty, reason: r.key);
      if (r.key != 'other') {
        expect(r.basis, isNotEmpty, reason: '${r.key}에 관련 기준이 없음');
      }
    }
    // 등급 3단계가 모두 쓰임
    expect(HazardRules.all.map((r) => r.severity).toSet(),
        Severity.values.toSet());
  });

  test('등급은 규칙표가 정함: AI가 등급을 다르게 줘도 종류의 등급으로', () {
    final r = ai([
      hz('minor_rust', severity: 'high'), // AI가 "위험"이라 해도 관찰
      hz('live_part_exposed', severity: 'low'), // AI가 "관찰"이라 해도 위험
      hz('corrosion'), // 등급을 안 줘도 주의
    ]);
    // 심각한 것부터
    expect(r.hazards.map((h) => h.category),
        ['live_part_exposed', 'corrosion', 'minor_rust']);
    expect(r.hazards.map((h) => h.severity),
        [Severity.high, Severity.medium, Severity.low]);
    expect(r.worst, Severity.high);
  });

  test('같은 종류는 이름을 다르게 적어도 언제나 같은 등급', () {
    for (final name in ['바닥 물기', '바닥 물 고임', '배관 누수']) {
      expect(ai([hz('leak', type: name)]).hazards.single.severity,
          Severity.medium);
    }
  });

  test('올림 규칙: 누수가 충전부 노출·전선 손상과 같은 사진에 있으면 위험으로(이유를 남김)', () {
    final alone = ai([hz('leak')]).hazards.single;
    expect(alone.severity, Severity.medium);
    expect(alone.ruleNote, isNull);

    for (final electrical in HazardRules.electricalHazards) {
      final r = ai([hz('leak'), hz(electrical)]);
      final leak = r.hazards.firstWhere((h) => h.category == 'leak');
      expect(leak.severity, Severity.high, reason: electrical);
      expect(leak.ruleNote, HazardRules.leakWithElectricalNote);
      expect(leak.ruleLine, contains('위험으로 올림'));
    }
    // 전기와 상관없는 위험과 함께면 그대로
    expect(
        ai([hz('leak'), hz('floor_obstacle')])
            .hazards
            .firstWhere((h) => h.category == 'leak')
            .severity,
        Severity.medium);
  });

  test('목록에 없는 종류(예전 형식)는 건드리지 않고, 기타는 주의', () {
    final r = ai([
      {'type': '옛 형식', 'description': '', 'action': '', 'severity': 'high'},
      hz('not_in_table', severity: 'low'),
      hz('other'),
    ]);
    Hazard of(String type) => r.hazards.firstWhere((h) => h.type == type);
    expect(of('옛 형식').severity, Severity.high);
    expect(of('옛 형식').rule, isNull);
    expect(of('옛 형식').ruleLine, isNull);
    expect(of('not_in_table').severity, Severity.low);
    expect(of('other').severity, Severity.medium);
  });

  test('저장된 기록은 그때 정한 등급 그대로(규칙표가 나중에 바뀌어도 기록은 안 바뀜) · 종류도 저장', () {
    final saved = ai([hz('leak'), hz('wire_damaged')]).toJson();
    final hazards = saved['hazards'] as List;
    expect(hazards.map((h) => h['category']).toSet(), {'wire_damaged', 'leak'});
    // 저장 형식에 등급·올림 이유가 함께 남음
    expect(hazards.map((h) => h['severity']), ['high', 'high']);
    expect(hazards.firstWhere((h) => h['category'] == 'leak')['rule_note'],
        HazardRules.leakWithElectricalNote);

    // 다시 읽을 때는 규칙표를 다시 적용하지 않음: 저장된 등급을 믿음
    final stored = HazardReport.fromJson({
      'summary': 's',
      'hazards': [hz('minor_rust', severity: 'high')],
    }, 0, const Size(1, 1));
    expect(stored.hazards.single.severity, Severity.high);
    expect(stored.hazards.single.rule!.label, '경미한 녹·얼룩');
  });

  test('기록 화면·공유 글용 한 줄: 분류 + 관련 기준(참고)', () {
    final h = ai([hz('rotating_unguarded')]).hazards.single;
    expect(h.ruleLine, startsWith('분류: 회전체 덮개 없음'));
    expect(h.ruleLine, contains('관련 기준(참고): '));
    expect(h.ruleLine, contains(h.rule!.basis.first));
  });

  test('자동 저장 중복 막기: AI가 이름을 다르게 써도 같은 종류면 1분 안에 한 번만', () {
    var now = DateTime(2026, 11, 10, 10);
    final g = AutoSaveGuard(now: () => now);
    expect(g.shouldSave(ai([hz('leak', type: '바닥 물기')])), isTrue);
    now = now.add(const Duration(seconds: 20));
    expect(g.shouldSave(ai([hz('leak', type: '바닥 물 고임')])), isFalse);
    // 다른 종류가 섞이면 저장
    expect(
        g.shouldSave(ai([hz('leak', type: '물 고임'), hz('corrosion')])), isTrue);
    // 기타는 종류로 묶지 않고 이름으로
    expect(g.shouldSave(ai([hz('other', type: '낙하 위험')])), isTrue);
    expect(g.shouldSave(ai([hz('other', type: '끼임 위험')])), isTrue);
    expect(g.shouldSave(ai([hz('other', type: '낙하 위험')])), isFalse);
  });

  test('가짜 AI도 규칙표를 거침: 위험 1 + 주의 1', () async {
    final r = await FakeHazardAnalyzer()
        .analyze(File('assets/test_frames/scene_01.jpg').readAsBytesSync());
    expect(r.hazards.map((h) => h.severity), [Severity.high, Severity.medium]);
    expect(r.hazards.map((h) => h.rule!.label), ['충전부 노출', '바닥 장애물']);
  });
}
