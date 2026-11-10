import '../analysis/hazard.dart';
import '../ui/format.dart';
import 'models.dart';

String _label(Severity s) => switch (s) {
      Severity.high => '위험',
      Severity.medium => '주의',
      Severity.low => '관찰',
    };

/// 메신저·업무일지에 붙여 넣을 점검 요약(사진 제외)
String inspectionReportText(Inspection i) {
  final b = StringBuffer()
    ..writeln('[시설 안전점검] ${i.location}')
    ..writeln('시작 ${fmtFull(i.startedAt)}'
        '${i.endedAt == null ? ' (진행 중)' : ' · 종료 ${fmtFull(i.endedAt!)}'}')
    ..writeln('발견 ${i.findings.length}건 · 미조치 ${i.openCount}건');
  final open = i.openBySeverity;
  if (open.values.any((v) => v > 0)) {
    b.writeln('미조치 위험요소: ${[
      for (final s in Severity.values)
        if (open[s]! > 0) '${_label(s)} ${open[s]}'
    ].join(', ')}');
  }
  var n = 1;
  for (final f in i.findings) {
    b
      ..writeln()
      ..writeln('${n++}. ${fmtTime(f.createdAt)} · ${f.source.label} '
          '${f.allIgnored ? '[오탐 처리] ' : f.finished ? '[조치 완료] ' : ''}'
          '${f.report.summary}');
    for (final h in f.report.hazards) {
      final st = switch (h.status) {
        HazardStatus.open => '',
        HazardStatus.resolved => ' (완료)',
        HazardStatus.ignored => ' (무시)',
      };
      b.writeln('   - [${_label(h.severity)}] ${h.type}$st: '
          '${h.description} → ${h.action}');
      // 등급을 정한 규칙(종류)과 관련 기준 — 왜 이 등급인지 받는 사람도 알 수 있게
      if (h.ruleLine != null) b.writeln('     ${h.ruleLine}');
    }
    if (f.memo.isNotEmpty) b.writeln('   메모: ${f.memo}');
  }
  return b.toString().trimRight();
}
