import 'dart:ui';

enum Severity { high, medium, low }

/// 기사가 위험 하나를 어떻게 처리했나. 카메라 화면에서 위험 박스를 눌러(지금은 탭, 다음 단계는 손) 바꿈
enum HazardStatus { open, resolved, ignored }

/// AI가 찾은 위험요소 하나.
class Hazard {
  final String type;
  final String description;
  final Severity severity;
  final String action;

  /// 스냅샷 기준 0..1 정규화 위치. AI가 위치를 못 짚으면 null
  final Rect? box;

  /// 처리 상태. 카메라 화면의 AI 결과와 저장된 기록이 같은 객체를 쓰므로 여기서 바꾸면 둘 다 반영
  HazardStatus status;
  DateTime? statusAt;

  /// 어떻게 바꿨나: tap(카메라 화면 탭) / hand(손, 다음 단계) / list(기록 화면)
  String? statusBy;

  /// 완료할 때 찍은 조치 후 사진(점검 폴더 안 파일 이름)
  String? afterPhoto;

  Hazard({
    required this.type,
    required this.description,
    required this.severity,
    required this.action,
    this.box,
    this.status = HazardStatus.open,
    this.statusAt,
    this.statusBy,
    this.afterPhoto,
  });

  /// open으로 되돌리면 처리 기록도 지움
  void setStatus(HazardStatus s,
      {String? by, String? afterPhoto, DateTime? at}) {
    status = s;
    final open = s == HazardStatus.open;
    statusAt = open ? null : (at ?? DateTime.now());
    statusBy = open ? null : by;
    this.afterPhoto = open ? null : afterPhoto;
  }

  factory Hazard.fromJson(Map<String, dynamic> j) => Hazard(
        type: j['type'] as String? ?? '',
        description: j['description'] as String? ?? '',
        severity: Severity.values.asNameMap()[j['severity']] ?? Severity.low,
        action: j['action'] as String? ?? '',
        box: box2d(j['box_2d']),
        status:
            HazardStatus.values.asNameMap()[j['status']] ?? HazardStatus.open,
        statusAt: DateTime.tryParse(j['statusAt'] as String? ?? ''),
        statusBy: j['statusBy'] as String?,
        afterPhoto: j['afterPhoto'] as String?,
      );

  /// 저장용. Gemini 응답과 같은 형식이라 [Hazard.fromJson]으로 그대로 다시 읽힘
  Map<String, dynamic> toJson() => {
        'type': type,
        'description': description,
        'severity': severity.name,
        'action': action,
        if (box != null)
          'box_2d': [box!.top, box!.left, box!.bottom, box!.right]
              .map((v) => (v * 1000).round())
              .toList(),
        if (status != HazardStatus.open) ...{
          'status': status.name,
          if (statusAt != null) 'statusAt': statusAt!.toIso8601String(),
          if (statusBy != null) 'statusBy': statusBy,
          if (afterPhoto != null) 'afterPhoto': afterPhoto,
        },
      };

  /// Gemini 공간 인식 형식: [ymin, xmin, ymax, xmax], 0~1000
  static Rect? box2d(Object? v) {
    if (v is! List || v.length != 4) return null;
    final n =
        v.map((e) => (e as num).toDouble().clamp(0, 1000) / 1000).toList();
    final r = Rect.fromLTRB(n[1], n[0], n[3], n[2]);
    return r.width > 0 && r.height > 0 ? r : null;
  }
}

/// 사진 속 설비 하나(위험 여부와 상관없이). AI가 짚어 주면 설비 전용 탐지기 학습 데이터가 됨
class Equipment {
  const Equipment(this.label, this.box);

  /// [labels]의 키(영문, 학습 데이터 클래스 이름)
  final String label;

  /// 스냅샷 기준 0..1 정규화 위치
  final Rect box;

  /// 기계실·전기실에서 탐지기가 알아볼 설비 종류. 순서 = 학습 데이터 클래스 번호이므로 뒤에만 추가
  static const labels = {
    'valve': '밸브',
    'pipe': '배관',
    'pump': '펌프',
    'motor': '모터',
    'electrical_panel': '분전반·제어반',
    'gauge': '계기',
    'fire_extinguisher': '소화기',
    'tank': '탱크',
    'duct': '덕트',
    'cable_tray': '케이블트레이',
  };

  String get name => labels[label] ?? label;

  /// 모르는 종류이거나 위치가 없으면 null(학습 데이터에 잘못 들어가지 않게)
  static Equipment? fromJson(Map<String, dynamic> j) {
    final label = j['label'];
    final box = Hazard.box2d(j['box_2d']);
    if (label is! String || !labels.containsKey(label) || box == null) {
      return null;
    }
    return Equipment(label, box);
  }

  Map<String, dynamic> toJson() => {
        'label': label,
        'box_2d': [box.top, box.left, box.bottom, box.right]
            .map((v) => (v * 1000).round())
            .toList(),
      };
}

/// 한 장면에 대한 점검 결과.
class HazardReport {
  final String summary;
  final List<Hazard> hazards;
  final int elapsedMs;

  /// 분석한 스냅샷의 (똑바로 선) 크기. 화면 미리보기와 비율이 다를 수 있어 박스 매핑에 사용
  final Size imageSize;

  /// 사진 속 설비 위치(설정 → 개발자 → 학습 데이터 모으기를 켰을 때만 AI가 채움)
  final List<Equipment> equipment;

  const HazardReport({
    required this.summary,
    required this.hazards,
    required this.elapsedMs,
    required this.imageSize,
    this.equipment = const [],
  });

  factory HazardReport.fromJson(
          Map<String, dynamic> j, int elapsedMs, Size imageSize) =>
      HazardReport(
        summary: j['summary'] as String? ?? '',
        hazards: (j['hazards'] as List? ?? const [])
            .map((h) => Hazard.fromJson(h as Map<String, dynamic>))
            .toList()
          ..sort((a, b) => a.severity.index.compareTo(b.severity.index)),
        elapsedMs: elapsedMs,
        imageSize: imageSize,
        equipment: [
          for (final e in j['equipment'] as List? ?? const [])
            if (Equipment.fromJson(e as Map<String, dynamic>) case final eq?) eq
        ],
      );

  /// 저장용(요약·위험요소·설비). 시간·크기는 저장하는 쪽에서 따로 보관
  Map<String, dynamic> toJson() => {
        'summary': summary,
        'hazards': [for (final h in hazards) h.toJson()],
        if (equipment.isNotEmpty)
          'equipment': [for (final e in equipment) e.toJson()],
      };

  /// 가장 높은 심각도(없으면 null)
  Severity? get worst => hazards.isEmpty ? null : hazards.first.severity;
}
