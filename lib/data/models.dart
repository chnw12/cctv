import 'dart:ui';
import '../analysis/hazard.dart';

/// 발견사항이 어떻게 기록됐는지
enum FindingSource {
  ai, // AI 점검 버튼
  auto, // 자동 점검(새 물체 등장)
  manual, // 사진만 찍고 직접 기록(오프라인·AI 미사용)
  ;

  /// 화면·CSV·공유 요약에 같이 쓰는 이름. 자동 점검으로 저장된 위험은 기사가 처리하기 전까지 "미확인 AI 제안"
  String get label => switch (this) {
        ai => 'AI 점검',
        auto => '자동 점검',
        manual => '직접 기록',
      };
}

/// 점검 중 기록한 한 장면: 사진 + AI 결과 + 조치 상태
class Finding {
  Finding({
    required this.id,
    required this.createdAt,
    required this.photo,
    required this.imageSize,
    required this.report,
    required this.source,
    this.resolved = false,
    this.memo = '',
  });

  final String id;
  final DateTime createdAt;

  /// 점검 폴더 안 사진 파일 이름
  final String photo;
  final Size imageSize;

  /// AI 결과(수동 기록이면 위험요소가 빈 결과). 나중에 AI 분석하면 바뀜
  HazardReport report;
  final FindingSource source;
  bool resolved;
  String memo;

  Severity? get worst => report.worst;

  /// 남은 일이 없나: 기록 전체를 "조치 완료"로 표시했거나, 위험이 있고 모두 완료·무시됨.
  /// (위험 없는 수동 기록은 표시한 대로). 모두 무시한 경우는 조치한 게 없으므로
  /// 화면·공유에서는 "조치 완료"가 아니라 [allIgnored]("오탐 처리")로 보여 줌
  bool get done =>
      resolved ||
      (report.hazards.isNotEmpty &&
          report.hazards.every((h) => h.status != HazardStatus.open));

  /// AI가 짚은 위험을 기사가 모두 오탐(무시)으로 처리함 → "조치 완료"가 아님
  bool get allIgnored =>
      !resolved &&
      report.hazards.isNotEmpty &&
      report.hazards.every((h) => h.status == HazardStatus.ignored);

  /// 화면·공유에서 "조치 완료"로 보여 줄지(모두 오탐 처리한 기록은 아님)
  bool get finished => done && !allIgnored;

  /// 아직 처리 안 된 위험(기록 전체를 조치 완료로 표시했으면 없음)
  List<Hazard> get openHazards => resolved
      ? const []
      : [
          for (final h in report.hazards)
            if (h.status == HazardStatus.open) h
        ];

  /// 사진만 찍고 아직 AI 분석 전인 기록의 요약 문구
  static const manualSummary = '직접 기록';

  /// 인터넷이 없어 사진만 남긴 기록 → 나중에 AI 분석 대상
  bool get needsAi =>
      source == FindingSource.manual &&
      report.summary == manualSummary &&
      report.hazards.isEmpty;

  Map<String, dynamic> toJson() => {
        'id': id,
        'createdAt': createdAt.toIso8601String(),
        'photo': photo,
        'imageW': imageSize.width,
        'imageH': imageSize.height,
        'aiMs': report.elapsedMs,
        'report': report.toJson(),
        'source': source.name,
        'resolved': resolved,
        'memo': memo,
      };

  factory Finding.fromJson(Map<String, dynamic> j) {
    final size = Size((j['imageW'] as num?)?.toDouble() ?? 0,
        (j['imageH'] as num?)?.toDouble() ?? 0);
    return Finding(
      id: j['id'] as String,
      createdAt: DateTime.parse(j['createdAt'] as String),
      photo: j['photo'] as String,
      imageSize: size,
      report: HazardReport.fromJson(
          (j['report'] as Map?)?.cast<String, dynamic>() ?? const {},
          (j['aiMs'] as num?)?.toInt() ?? 0,
          size),
      source: FindingSource.values.asNameMap()[j['source']] ?? FindingSource.ai,
      resolved: j['resolved'] as bool? ?? false,
      memo: j['memo'] as String? ?? '',
    );
  }
}

/// 한 번의 점검(장소 하나를 돌아본 기록)
class Inspection {
  Inspection({
    required this.id,
    required this.location,
    required this.startedAt,
    this.endedAt,
    List<Finding>? findings,
  }) : findings = findings ?? [];

  final String id;
  String location;
  final DateTime startedAt;
  DateTime? endedAt;
  final List<Finding> findings;

  bool get inProgress => endedAt == null;

  /// 미조치 위험요소가 있는 발견 수
  int get openCount => findings.where((f) => f.openHazards.isNotEmpty).length;

  /// 심각도별 위험요소 수(미조치 기준, 완료·무시한 위험은 뺌)
  Map<Severity, int> get openBySeverity {
    final m = {for (final s in Severity.values) s: 0};
    for (final f in findings) {
      for (final h in f.openHazards) {
        m[h.severity] = m[h.severity]! + 1;
      }
    }
    return m;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'location': location,
        'startedAt': startedAt.toIso8601String(),
        if (endedAt != null) 'endedAt': endedAt!.toIso8601String(),
        'findings': [for (final f in findings) f.toJson()],
      };

  factory Inspection.fromJson(Map<String, dynamic> j) => Inspection(
        id: j['id'] as String,
        location: j['location'] as String? ?? '',
        startedAt: DateTime.parse(j['startedAt'] as String),
        endedAt: j['endedAt'] == null
            ? null
            : DateTime.parse(j['endedAt'] as String),
        findings: [
          for (final f in (j['findings'] as List? ?? const []))
            Finding.fromJson((f as Map).cast<String, dynamic>())
        ],
      );
}
