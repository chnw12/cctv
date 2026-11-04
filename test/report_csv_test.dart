import 'dart:ui';
import 'package:facility_camera/analysis/hazard.dart';
import 'package:facility_camera/data/models.dart';
import 'package:facility_camera/data/report_csv.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('CSV: 위험마다 한 줄, 쉼표·따옴표 처리, 엑셀용 BOM', () {
    final i = Inspection(
        id: 'a', location: 'B2 기계실', startedAt: DateTime(2026, 10, 31, 9));
    i.findings.add(Finding(
      id: 'f1',
      createdAt: DateTime(2026, 10, 31, 9, 5),
      photo: 'f1.jpg',
      imageSize: const Size(1, 1),
      report: HazardReport.fromJson({
        'summary': '누수, 전선',
        'hazards': [
          {
            'type': '누수',
            'description': '바닥에 "물"',
            'severity': 'medium',
            'action': '닦기'
          },
          {
            'type': '전선',
            'description': '노출',
            'severity': 'high',
            'action': '덮개'
          },
        ],
      }, 0, const Size(1, 1)),
      source: FindingSource.ai,
      resolved: true,
      memo: '김기사',
    ));
    final csv = inspectionCsv(i);
    expect(csv.startsWith('﻿장소,시각,심각도'), isTrue);
    final lines = csv.trim().split('\r\n');
    expect(lines, hasLength(3)); // 머리 + 위험 2줄(심각도 순)
    expect(lines[1], startsWith('B2 기계실,2026-10-31 09:05,위험,전선'));
    expect(lines[2], contains('"바닥에 ""물"""'));
    expect(lines[2], contains(',O,김기사,f1.jpg,"누수, 전선"'));
  });
}
