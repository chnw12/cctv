import '../analysis/hazard.dart';
import '../ui/format.dart';
import 'models.dart';

String _label(Severity s) => switch (s) {
      Severity.high => '위험',
      Severity.medium => '주의',
      Severity.low => '관찰',
    };

String _cell(String v) {
  // 쉼표·따옴표·줄바꿈이 있으면 따옴표로 감싸고 안의 따옴표는 두 번(CSV 규칙)
  final needs = v.contains(',') || v.contains('"') || v.contains('\n');
  return needs ? '"${v.replaceAll('"', '""')}"' : v;
}

String _status(HazardStatus s) => switch (s) {
      HazardStatus.open => '',
      HazardStatus.resolved => '완료',
      HazardStatus.ignored => '무시',
    };

/// 엑셀·업무일지용 CSV: 위험요소 한 줄씩(위험이 없는 기록은 요약 한 줄).
/// 처리: 위험별 완료·무시(카메라 화면·기록 화면에서 누른 것), 조치후사진: 완료 때 찍은 사진 파일
/// 엑셀에서 한글이 깨지지 않게 맨 앞에 BOM을 붙임
String inspectionCsv(Inspection i) {
  final rows = <List<String>>[
    [
      '장소',
      '시각',
      '심각도',
      '위험',
      '근거',
      '조치',
      '처리',
      '조치후사진',
      '조치완료',
      '메모',
      '사진',
      '요약'
    ],
  ];
  for (final f in i.findings) {
    final common = [i.location, fmtFull(f.createdAt)];
    final tail = [f.done ? 'O' : '', f.memo, f.photo, f.report.summary];
    if (f.report.hazards.isEmpty) {
      rows.add([...common, '', '', '', '', '', '', ...tail]);
    }
    for (final h in f.report.hazards) {
      rows.add([
        ...common,
        _label(h.severity),
        h.type,
        h.description,
        h.action,
        _status(h.status),
        h.afterPhoto ?? '',
        ...tail,
      ]);
    }
  }
  return '﻿${rows.map((r) => r.map(_cell).join(',')).join('\r\n')}\r\n';
}
