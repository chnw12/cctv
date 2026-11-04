import '../core/frame.dart';

/// 탐지기 인터페이스. 지금은 ML Kit, 나중에 YOLO(TFLite) 등으로 교체해도
/// 나머지 코드는 그대로입니다.
abstract class Detector {
  Future<List<Detection>> detect(Frame frame);
  Future<void> close();
}
