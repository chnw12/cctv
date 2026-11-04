import 'package:facility_camera/core/frame.dart';
import 'package:facility_camera/detection/equipment_detector.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 설비 탐지기(Dart 쪽): 안드로이드 채널에 넘기는 값과 돌려받은 박스 해석
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const ch = MethodChannel('facility_camera/equipment');
  final calls = <Map<Object?, Object?>>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ch, (call) async {
      if (call.method != 'detect') return null;
      calls.add(call.arguments as Map<Object?, Object?>);
      return {
        'delegate': 'cpu',
        'ms': 42,
        'boxes': [0.1, 0.2, 0.3, 0.4, 0.9, 1], // 배관 하나
      };
    });
  });
  tearDown(() => TestDefaultBinaryMessengerBinding
      .instance.defaultBinaryMessenger
      .setMockMethodCallHandler(ch, null));

  test('카메라 프레임: 똑바로 세워 모델 크기 정도로 줄인 RGBA를 넘김(720p → 3칸마다)', () async {
    // 1280x720 센서, 90° → 똑바로 선 720x1280. 480 입력이면 올림으로 3칸마다 → 240x426
    const w = 1280, h = 720;
    final frame = Frame.raw(
      timestampMs: 0,
      format: FrameFormat.nv21,
      bytes: Uint8List(w * h * 3 ~/ 2),
      rawSize: const Size(1280, 720),
      rotationDegrees: 90,
      bytesPerRow: w,
      uprightSize: const Size(720, 1280),
    );
    final det = EquipmentDetector();
    final out = await det.detect(frame);
    expect(calls.single['w'], 240);
    expect(calls.single['h'], 426);
    expect((calls.single['rgba'] as Uint8List).length, 240 * 426 * 4);
    expect(calls.single['minConf'], det.minConfidence);
    expect(out.single.label, '배관');
    expect(out.single.box, const Rect.fromLTRB(0.1, 0.2, 0.3, 0.4));
    expect(det.lastMs, 42);
  });

  test('테스트 이미지(사진 파일): 경로만 넘기고 읽기·줄이기는 안드로이드 쪽', () async {
    await EquipmentDetector().detect(const Frame.file(
        timestampMs: 0, filePath: '/x/panel.jpg', uprightSize: Size(1, 1)));
    expect(calls.single['path'], '/x/panel.jpg');
    expect(calls.single['size'], 480);
    expect(calls.single.containsKey('rgba'), isFalse);
  });
}
