import 'dart:typed_data';
import '../core/jpeg.dart';
import 'hazard.dart';
import 'hazard_analyzer.dart';

/// 키 없이 화면 흐름(스냅샷 → 결과 패널 → 위치 박스)을 확인하는 가짜 분석기.
/// `--dart-define=FAKE_AI=true` 로 켭니다. 네트워크는 쓰지 않습니다.
class FakeHazardAnalyzer implements HazardAnalyzer {
  @override
  String? get unavailableReason => null;

  @override
  String get description => '가짜 AI(FAKE_AI, 네트워크 안 씀)';

  @override
  Future<HazardReport> analyze(Uint8List jpeg,
      {String? place, bool equipment = false}) async {
    final size = await encodedImageSize(jpeg);
    await Future<void>.delayed(const Duration(milliseconds: 800));
    return HazardReport.fromJson({
      'summary': '(가짜 응답) 스냅샷 ${size.width.toInt()}x${size.height.toInt()}, '
          '${(jpeg.length / 1024).round()}KB',
      'hazards': [
        {
          'type': '테스트 위험',
          'description': '가운데 영역 표시 확인용',
          'severity': 'high',
          'action': '박스가 화면 가운데에 그려지는지 확인',
          'box_2d': [400, 300, 600, 700],
        },
        {
          'type': '테스트 주의',
          'description': '왼쪽 위 모서리',
          'severity': 'medium',
          'action': '모서리 좌표 확인',
          'box_2d': [0, 0, 150, 250],
        },
      ],
      if (equipment)
        'equipment': [
          {
            'label': 'valve',
            'box_2d': [400, 300, 600, 700]
          },
          {
            'label': 'pipe',
            'box_2d': [700, 0, 800, 1000]
          },
        ],
    }, 800, size);
  }
}
