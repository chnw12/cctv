import 'package:facility_camera/analysis/hazard.dart';
import 'package:facility_camera/camera/camera_pipeline.dart';
import 'package:facility_camera/data/models.dart';
import 'package:facility_camera/data/report_text.dart';
import 'package:facility_camera/ui/hazard_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('짧은 내용이면 패널이 최대 높이까지 늘어나지 않음', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              HazardPanel(state: const AiState(error: '키 없음'), onClose: () {}),
            ],
          ),
        ),
      ),
    ));
    final h = tester.getSize(find.byType(HazardPanel)).height;
    expect(h, lessThan(100));
  });

  HazardReport report() => HazardReport.fromAi({
        'summary': '분전반 앞',
        'hazards': [
          {
            'category': 'panel_obstructed',
            'type': '분전반 앞 박스',
            'description': '박스가 문을 막음',
            'action': '옮기기',
          },
        ],
      }, 0, const Size(1, 1));

  testWidgets('종류·관련 기준 줄: 기록 화면에서만 보이고 카메라 결과 패널에는 없음', (tester) async {
    Future<void> show(bool showRule) => tester.pumpWidget(MaterialApp(
        home: Scaffold(body: HazardList(report(), showRule: showRule))));

    await show(false);
    expect(find.textContaining('분류: '), findsNothing);

    await show(true);
    final line = find.textContaining('분류: 분전반 앞 적치');
    expect(line, findsOneWidget);
    // 왜 '주의'인지 근거가 되는 기준이 같이 보임(참고용)
    expect(tester.widget<Text>(line).data, contains('관련 기준(참고): '));
    expect(tester.widget<Text>(line).data, contains('제310조'));
  });

  test('공유 글에도 종류·관련 기준이 한 줄 붙음(종류가 없는 예전 기록은 그대로)', () {
    final i = Inspection(
        id: 'a', location: 'B2 전기실', startedAt: DateTime(2026, 11, 10, 9));
    i.findings.addAll([
      Finding(
          id: 'f1',
          createdAt: DateTime(2026, 11, 10, 9, 5),
          photo: 'f1.jpg',
          imageSize: const Size(1, 1),
          report: report(),
          source: FindingSource.ai),
      Finding(
          id: 'f2',
          createdAt: DateTime(2026, 11, 10, 9, 6),
          photo: 'f2.jpg',
          imageSize: const Size(1, 1),
          report: HazardReport.fromJson({
            'summary': '예전 기록',
            'hazards': [
              {'type': '누수', 'description': '', 'severity': 'high', 'action': ''}
            ],
          }, 0, const Size(1, 1)),
          source: FindingSource.ai),
    ]);
    final text = inspectionReportText(i);
    expect(text, contains('- [주의] 분전반 앞 박스: 박스가 문을 막음 → 옮기기'));
    expect(text, contains('분류: 분전반 앞 적치 · 관련 기준(참고): '));
    expect('분류: '.allMatches(text), hasLength(1)); // 예전 기록에는 안 붙음
  });
}
