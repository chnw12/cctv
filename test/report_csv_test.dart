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
            'category': 'leak',
            'description': '바닥에 "물"',
            'severity': 'medium',
            'action': '닦기'
          },
          {
            'type': '전선',
            'category': 'live_part_exposed',
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
    expect(csv.startsWith('﻿장소,시각,기록 방식,심각도'), isTrue);
    final lines = csv.trim().split('\r\n');
    expect(lines, hasLength(3)); // 머리 + 위험 2줄(심각도 순)
    // 분류 칸: 등급을 정한 규칙표의 종류
    expect(lines[1],
        startsWith('B2 기계실,2026-10-31 09:05,AI 점검,위험,충전부 노출,전선'));
    expect(lines[2], contains(',주의,누수·누유,누수,'));
    expect(lines[2], contains('"바닥에 ""물"""'));
    expect(lines[2], contains(',O,김기사,f1.jpg,"누수, 전선"'));
  });

  test('CSV: 자동 점검·직접 기록도 기록 방식 열에 보임(자동 저장분을 사람이 확인했는지 구분용)', () {
    Finding f(String id, FindingSource src, List<Map<String, Object>> hs) =>
        Finding(
          id: id,
          createdAt: DateTime(2026, 11, 12, 10),
          photo: '$id.jpg',
          imageSize: const Size(1, 1),
          report: HazardReport.fromJson(
              {'summary': id, 'hazards': hs}, 0, const Size(1, 1)),
          source: src,
        );
    final i = Inspection(
        id: 'a', location: 'B2', startedAt: DateTime(2026, 11, 12, 9))
      ..findings.addAll([
        f('auto1', FindingSource.auto, [
          {'type': '누수', 'description': '', 'severity': 'high', 'action': ''}
        ]),
        f('man1', FindingSource.manual, []),
      ]);
    final lines = inspectionCsv(i).trim().split('\r\n');
    // 종류가 없는 예전 기록은 분류 칸이 비어 있음
    expect(lines[1], startsWith('B2,2026-11-12 10:00,자동 점검,위험,,누수'));
    expect(lines[2], startsWith('B2,2026-11-12 10:00,직접 기록,,'));
    // 머리와 같은 칸 수(위험 없는 줄도)
    expect(lines.map((l) => l.split(',').length).toSet(), {15});
  });
}
