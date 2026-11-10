import 'dart:typed_data';
import 'hazard.dart';

/// 장면(JPEG) 한 장을 보고 위험요소를 판단합니다.
/// 지금은 Claude(기본)·Gemini 직접 호출(default_analyzer.dart에서 고름), 실서비스에서는 서버 경유 구현으로 교체합니다.
abstract class HazardAnalyzer {
  /// 키가 없는 등 사용할 수 없으면 이유, 쓸 수 있으면 null
  String? get unavailableReason;

  /// 화면 표시용 설명(예: "Claude claude-sonnet-5-5 · effort low")
  String get description;

  /// place: 점검 장소(예: "B2 기계실"). 장소에 맞는 위험을 더 잘 보게 프롬프트에 넣음.
  /// equipment: 위험과 별도로 사진 속 설비 위치도 받음(탐지기 학습 데이터, 응답이 조금 길어짐)
  Future<HazardReport> analyze(Uint8List jpeg,
      {String? place, bool equipment = false});
}
