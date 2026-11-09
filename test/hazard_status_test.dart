import 'dart:ui';
import 'package:facility_camera/analysis/hazard.dart';
import 'package:facility_camera/data/models.dart';
import 'package:facility_camera/data/report_csv.dart';
import 'package:facility_camera/data/report_text.dart';
import 'package:facility_camera/ui/box_painter.dart';
import 'package:flutter_test/flutter_test.dart';

Hazard _h(String type, Rect? box, {Severity s = Severity.medium}) =>
    Hazard(type: type, description: '', severity: s, action: '', box: box);

HazardReport _r(List<Hazard> hs) => HazardReport(
    summary: '', hazards: hs, elapsedMs: 0, imageSize: const Size(100, 200));

Finding _f(HazardReport r, {bool resolved = false}) => Finding(
    id: 'f',
    createdAt: DateTime(2026, 11, 3),
    photo: 'f.jpg',
    imageSize: const Size(100, 200),
    report: r,
    source: FindingSource.ai,
    resolved: resolved);

void main() {
  test('상태 JSON: 미조치는 상태를 안 씀, 처리하면 시각·방법·조치 후 사진까지 저장·복원', () {
    final h = _h('누수', const Rect.fromLTRB(0.1, 0.2, 0.3, 0.4));
    expect(h.toJson().containsKey('status'), isFalse);
    expect(Hazard.fromJson(h.toJson()).status, HazardStatus.open);

    h.setStatus(HazardStatus.resolved,
        by: 'tap', afterPhoto: 'f_after0.jpg', at: DateTime(2026, 11, 3, 10));
    final back = Hazard.fromJson(h.toJson());
    expect(back.status, HazardStatus.resolved);
    expect(back.statusBy, 'tap');
    expect(back.afterPhoto, 'f_after0.jpg');
    expect(back.statusAt, DateTime(2026, 11, 3, 10));
    expect(back.box, h.box);

    h.setStatus(HazardStatus.open);
    expect([h.statusAt, h.statusBy, h.afterPhoto], [null, null, null]);
  });

  test('조치 완료 판단: 위험이 모두 완료·무시되면 끝, 기록 전체 표시도 인정', () {
    final a = _h('누수', null, s: Severity.high), b = _h('전선', null);
    final f = _f(_r([a, b]));
    final i = Inspection(id: 'i', location: '', startedAt: DateTime(2026))
      ..findings.add(f);
    expect(f.done, isFalse);
    expect(i.openBySeverity[Severity.high], 1);

    a.setStatus(HazardStatus.resolved, by: 'tap');
    expect(f.openHazards, [b]);
    expect(i.openBySeverity[Severity.high], 0);
    expect(f.done, isFalse);
    b.setStatus(HazardStatus.ignored, by: 'tap');
    expect(f.done, isTrue);
    expect(i.openCount, 0);

    // 위험 없는 수동 기록은 표시한 대로
    expect(_f(_r([])).done, isFalse);
    expect(_f(_r([]), resolved: true).done, isTrue);
    expect(_f(_r([_h('x', null)]), resolved: true).openHazards, isEmpty);
  });

  test('모두 무시(오탐)한 기록은 "조치 완료"가 아니라 "오탐 처리" — 요약·CSV도', () {
    final a = _h('누수', null, s: Severity.high), b = _h('전선', null);
    final f = _f(_r([a, b]));
    final i = Inspection(id: 'i', location: 'B2', startedAt: DateTime(2026))
      ..findings.add(f);
    a.setStatus(HazardStatus.ignored, by: 'tap');
    b.setStatus(HazardStatus.ignored, by: 'list');
    expect(f.done, isTrue); // 남은 일은 없음(미조치에서 빠짐)
    expect(f.allIgnored, isTrue);
    expect(f.finished, isFalse); // 하지만 조치한 것은 없음
    expect(i.openCount, 0);
    final text = inspectionReportText(i);
    expect(text, contains('[오탐 처리]'));
    expect(text, isNot(contains('[조치 완료]')));
    expect(inspectionCsv(i).split('\r\n')[1], contains(',오탐,'));

    // 하나라도 완료하면 조치 완료
    b.setStatus(HazardStatus.resolved, by: 'tap');
    expect([f.allIgnored, f.finished], [false, true]);
    expect(inspectionReportText(i), contains('[조치 완료]'));
    // 기록 전체를 "조치 완료"로 표시해도 조치 완료
    b.setStatus(HazardStatus.ignored, by: 'tap');
    f.resolved = true;
    expect([f.allIgnored, f.finished], [false, true]);
  });

  test('탭 판정: 처리 안 된 위험만, 손가락 여유, 겹치면 작은(안쪽) 박스', () {
    // 이미지 100x200을 화면 100x200에 그대로 → 0..1 좌표 × 화면 크기
    const view = Size(100, 200);
    final big = _h('큰', const Rect.fromLTRB(0.1, 0.1, 0.9, 0.9));
    final small = _h('작은', const Rect.fromLTRB(0.4, 0.4, 0.6, 0.6));
    final r = _r([big, small]);
    expect(HazardBoxPainter.hazardAt(r, view, const Offset(50, 100)), 1);
    expect(HazardBoxPainter.hazardAt(r, view, const Offset(20, 30)), 0);
    // 박스(10..90 x) 바깥 6px 은 여유(16px) 안 → 잡힘, 바깥 30px 은 안 잡힘
    expect(HazardBoxPainter.hazardAt(r, view, const Offset(4, 100)), 0);
    expect(HazardBoxPainter.hazardAt(r, view, const Offset(50, 195), slop: 0),
        isNull);

    small.setStatus(HazardStatus.resolved, by: 'tap');
    expect(HazardBoxPainter.hazardAt(r, view, const Offset(50, 100)), 0,
        reason: '완료한 위험은 다시 고르지 않음 → 아래 큰 박스');
    big.setStatus(HazardStatus.ignored, by: 'tap');
    expect(HazardBoxPainter.hazardAt(r, view, const Offset(50, 100)), isNull);

    // 무시한 위험은 카메라 화면에서 안 그림(기록 화면은 includeIgnored)
    expect(HazardBoxPainter.viewRects(r, view).keys, [1]);
    expect(
        HazardBoxPainter.viewRects(r, view, includeIgnored: true).keys, [0, 1]);
  });
}
