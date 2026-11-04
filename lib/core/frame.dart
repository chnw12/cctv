import 'dart:typed_data';
import 'dart:ui';

enum FrameFormat { nv21, bgra8888, file }

/// 모든 입력(폰 카메라, 이미지 묶음, 나중에 오즈모)이 이 형태로 통일됩니다.
/// 탐지기는 Frame만 보고, 입력이 어디서 왔는지는 모릅니다.
class Frame {
  final int timestampMs;
  final FrameFormat format;

  /// 회전 보정 후(사람 눈에 똑바로 보이는) 이미지 크기
  final Size uprightSize;

  // 원본 바이트 입력(카메라 스트림)
  final Uint8List? bytes;
  final Size? rawSize;
  final int rotationDegrees;
  final int bytesPerRow;

  // 파일 입력(테스트 이미지)
  final String? filePath;

  const Frame.raw({
    required this.timestampMs,
    required this.format,
    required this.bytes,
    required this.rawSize,
    required this.rotationDegrees,
    required this.bytesPerRow,
    required this.uprightSize,
  }) : filePath = null;

  const Frame.file({
    required this.timestampMs,
    required this.filePath,
    required this.uprightSize,
  })  : format = FrameFormat.file,
        bytes = null,
        rawSize = null,
        rotationDegrees = 0,
        bytesPerRow = 0;
}

/// 탐지 결과. 박스는 0~1로 정규화(똑바로 선 이미지 기준)해서
/// 화면 크기·입력 해상도와 무관하게 그릴 수 있습니다.
class Detection {
  final int? trackingId;
  final Rect box; // normalized 0..1
  final String label;
  final double confidence;

  const Detection({
    required this.trackingId,
    required this.box,
    required this.label,
    required this.confidence,
  });
}
