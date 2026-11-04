import 'dart:ui';
import 'package:google_mlkit_object_detection/google_mlkit_object_detection.dart';
import '../core/frame.dart';
import 'detector.dart';

/// 폰 안(온디바이스)에서 돌아가는 탐지.
/// 기본은 single 모드(프레임마다 독립 탐지)이고 추적 ID는 TrackingDetector가 붙입니다.
/// stream 모드의 내장 추적은 입력 FPS가 낮으면 계속 리셋되어 탐지가 0개가 됩니다(에뮬레이터 5FPS에서 확인).
class MlKitDetector implements Detector {
  MlKitDetector({this.stream = false});
  final bool stream;

  late final ObjectDetector _d = ObjectDetector(
    options: ObjectDetectorOptions(
      mode: stream ? DetectionMode.stream : DetectionMode.single,
      classifyObjects: true,
      multipleObjects: true,
    ),
  );

  @override
  Future<List<Detection>> detect(Frame f) async {
    final input = _toInput(f);
    final objs = await _d.processImage(input);
    final w = f.uprightSize.width, h = f.uprightSize.height;

    return objs.map((o) {
      final r = o.boundingBox;
      final labels = o.labels.toList()
        ..sort((a, b) => b.confidence.compareTo(a.confidence));
      final best = labels.isEmpty ? null : labels.first;
      return Detection(
        trackingId: o.trackingId,
        box: Rect.fromLTRB(
          (r.left / w).clamp(0.0, 1.0),
          (r.top / h).clamp(0.0, 1.0),
          (r.right / w).clamp(0.0, 1.0),
          (r.bottom / h).clamp(0.0, 1.0),
        ),
        label: best?.text ?? '', // 기본 모델은 5개 대분류뿐이라 대부분 비어 있음
        confidence: best?.confidence ?? 0,
      );
    }).toList();
  }

  InputImage _toInput(Frame f) {
    if (f.format == FrameFormat.file) {
      return InputImage.fromFilePath(f.filePath!);
    }
    return InputImage.fromBytes(
      bytes: f.bytes!,
      metadata: InputImageMetadata(
        size: f.rawSize!,
        rotation: InputImageRotationValue.fromRawValue(f.rotationDegrees) ??
            InputImageRotation.rotation0deg,
        format: f.format == FrameFormat.nv21
            ? InputImageFormat.nv21
            : InputImageFormat.bgra8888,
        bytesPerRow: f.bytesPerRow,
      ),
    );
  }

  @override
  Future<void> close() => _d.close();
}
