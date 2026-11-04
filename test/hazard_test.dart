import 'dart:ui';
import 'package:facility_camera/analysis/hazard.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Gemini JSON → 심각도 순 정렬, box_2d는 [ymin,xmin,ymax,xmax]/1000', () {
    final r = HazardReport.fromJson({
      'summary': '기계실',
      'hazards': [
        {'type': '물웅덩이', 'description': '', 'severity': 'low', 'action': ''},
        {
          'type': '분전반 열림',
          'description': '',
          'severity': 'high',
          'action': '',
          'box_2d': [100, 200, 500, 600],
        },
      ],
    }, 1234, const Size(768, 1024));

    expect(r.hazards.map((h) => h.severity), [Severity.high, Severity.low]);
    expect(r.hazards.first.box, const Rect.fromLTRB(0.2, 0.1, 0.6, 0.5));
    expect(r.hazards.last.box, isNull);
  });

  test('잘못된 box_2d·알 수 없는 severity는 안전하게 무시', () {
    final h = Hazard.fromJson({
      'type': 'x',
      'severity': 'critical',
      'box_2d': [500, 500, 500, 600], // 높이 0
    });
    expect(h.severity, Severity.low);
    expect(h.box, isNull);
    expect(
        Hazard.fromJson({
          'box_2d': [1, 2]
        }).box,
        isNull);
  });
}
