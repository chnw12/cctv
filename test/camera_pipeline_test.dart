import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show PictureRecorder;
import 'package:camera/camera.dart' show CameraException, ResolutionPreset;
import 'package:facility_camera/analysis/fake_hazard_analyzer.dart';
import 'package:facility_camera/analysis/hazard.dart';
import 'package:facility_camera/analysis/hazard_analyzer.dart';
import 'package:facility_camera/camera/camera_pipeline.dart';
import 'package:facility_camera/camera/camera_view.dart';
import 'package:facility_camera/core/frame.dart';
import 'package:facility_camera/data/app_settings.dart';
import 'package:facility_camera/detection/detector.dart';
import 'package:facility_camera/hands/hand_tracker.dart';
import 'package:facility_camera/motion/camera_motion.dart';
import 'package:facility_camera/ui/box_painter.dart';
import 'package:facility_camera/sources/frame_source.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 가짜 카메라: 테스트가 프레임을 직접 넣음
class _FakeSource implements FrameSource, CameraControls {
  _FakeSource(this.jpeg, {this.failWith});
  final Uint8List jpeg;
  final Object? failWith;
  final _out = StreamController<Frame>.broadcast();
  bool started = false, disposed = false;
  int t = 0;

  void emit() => _out.add(Frame.file(
      timestampMs: t += 100, filePath: '', uprightSize: const Size(720, 1280)));

  @override
  String get name => 'fake';
  @override
  ValueListenable<double> get aspectRatio => ValueNotifier(9 / 16);
  @override
  Stream<Frame> get frames => _out.stream;
  @override
  Future<void> start() async {
    if (failWith != null) throw failWith!;
    started = true;
  }

  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {
    disposed = true;
    await _out.close();
  }

  @override
  Future<Uint8List> snapshotJpeg() async => jpeg;
  @override
  Widget buildPreview(BuildContext context) => const SizedBox();
  @override
  CameraControls? get controls => this;

  // 카메라 조작 기록
  @override
  bool torchOn = false;
  @override
  double zoom = 1;
  @override
  double get minZoom => 1;
  @override
  double get maxZoom => 4;
  @override
  Future<void> setTorch(bool on) async => torchOn = on;
  double ev = 0;
  @override
  double get maxExposureOffset => 2;
  @override
  Future<void> setExposureOffset(double v) async => ev = v;
  @override
  Size? lensFov;

  /// 밝기(Y)가 일정한 NV21 프레임(어두움·밝음 판정 테스트용)
  void emitLuma(int y) {
    const w = 64, h = 48;
    final bytes = Uint8List(w * h * 3 ~/ 2)..fillRange(0, w * h, y);
    _out.add(Frame.raw(
        timestampMs: t += 100,
        format: FrameFormat.nv21,
        bytes: bytes,
        rawSize: const Size(w * 1.0, h * 1.0),
        rotationDegrees: 90,
        bytesPerRow: w,
        uprightSize: const Size(h * 1.0, w * 1.0)));
  }

  @override
  Future<void> setZoom(double z) async => zoom = z;
  @override
  Future<void> focusAt(Offset p) async {}
}

/// 가짜 탐지기: 매 프레임 같은 자리에 물체 하나(추적기가 3번째에 ID 부여)
class _OneBox implements Detector {
  Rect box = const Rect.fromLTWH(0.3, 0.3, 0.2, 0.2);
  @override
  Future<List<Detection>> detect(Frame f) async =>
      [Detection(trackingId: null, box: box, label: '', confidence: 0)];
  @override
  Future<void> close() async {}
}

class _Ai implements HazardAnalyzer {
  _Ai({this.reason});
  final String? reason;
  int calls = 0;
  @override
  String? get unavailableReason => reason;
  @override
  String get description => 'fake';
  @override
  Future<HazardReport> analyze(Uint8List jpeg,
      {String? place, bool equipment = false}) async {
    calls++;
    return HazardReport.fromJson({
      'summary': '누수',
      'hazards': [
        {'type': '누수', 'description': '', 'severity': 'high', 'action': ''}
      ],
    }, 10, const Size(720, 1280));
  }
}

class _FailAi extends _Ai {
  @override
  Future<HazardReport> analyze(Uint8List jpeg,
          {String? place, bool equipment = false}) async =>
      throw StateError('인터넷에 연결되어 있지 않습니다.');
}

/// 아무것도 못 잡는 탐지기
class _NoBox implements Detector {
  @override
  Future<List<Detection>> detect(Frame f) async => const [];
  @override
  Future<void> close() async {}
}

/// 몇 번 불렸는지 세는 탐지기(절전 테스트용)
class _Counting extends _NoBox {
  int calls = 0;
  @override
  Future<List<Detection>> detect(Frame f) async {
    calls++;
    return const [];
  }
}

/// 실기기 ML Kit 흉내: 물체 하나는 늘 잡히고, 다른 자리 박스가 세 번에 한 번 잠깐 나옴(물체 수 1↔2,
/// 미확정은 1번 놓침까지만 살려 두므로 두 번 연달아 빠지는 박스엔 ID가 안 붙음).
/// second를 켜면 두 번째 물체가 계속 잡힘(새 확정 ID)
class _Flicker extends _NoBox {
  int calls = 0;
  bool second = false;
  @override
  Future<List<Detection>> detect(Frame f) async {
    calls++;
    return [
      const Detection(
          trackingId: null,
          box: Rect.fromLTWH(0.1, 0.1, 0.2, 0.2),
          label: '',
          confidence: 0),
      if (second || calls % 3 == 0)
        const Detection(
            trackingId: null,
            box: Rect.fromLTWH(0.6, 0.6, 0.2, 0.2),
            label: '',
            confidence: 0),
    ];
  }
}

/// 테스트가 풀어 줄 때까지 끝나지 않는 탐지기(처리 중 프레임 대기 테스트용)
class _Gated extends _NoBox {
  final seen = <int>[];
  Completer<void>? _gate;
  void release() => _gate?.complete();
  @override
  Future<List<Detection>> detect(Frame f) async {
    seen.add(f.timestampMs);
    await (_gate = Completer<void>()).future;
    return const [];
  }
}

/// 트랙 안쪽에 위험 박스 하나를 돌려주는 가짜 AI
class _BoxAi extends _Ai {
  @override
  Future<HazardReport> analyze(Uint8List jpeg,
          {String? place, bool equipment = false}) async =>
      HazardReport.fromJson({
        'summary': '누수',
        'hazards': [
          {
            'type': '누수',
            'description': '',
            'severity': 'high',
            'action': '',
            'box_2d': [320, 320, 420, 420],
          }
        ],
      }, 10, const Size(720, 1280));
}

Future<void> _until(bool Function() ok) async {
  for (var i = 0; i < 400 && !ok(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(ok(), isTrue, reason: '조건이 시간 안에 만족되지 않음');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  late AppSettings settings;
  final jpeg = File('assets/test_frames/scene_01.jpg').readAsBytesSync();

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('fc_pipe_');
    settings = AppSettings(File('${tmp.path}/s.json'))..gyro = false;
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('프레임 → 탐지·추적 → 3번 이상·0.4초 이상 잡히면 ID(100ms 간격이면 5번째)', () async {
    final src = _FakeSource(jpeg);
    final p = CameraPipeline(
        settings: settings,
        analyzer: _Ai(),
        sourceFactory: (_) => src,
        detectorFactory: _OneBox.new);
    await p.open(SourceKind.camera);
    expect(src.started, isTrue);
    for (var i = 0; i < 4; i++) {
      src.emit();
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(p.detections.value.single.trackingId, isNull,
        reason: '0.3초(4번)까지는 ID 없음');
    src.emit();
    await _until(() => p.detections.value.firstOrNull?.trackingId != null);
    expect(p.detections.value.single.trackingId, 1);
    expect(p.metrics.value.count, 1);
    p.dispose();
  });

  test('처리 중에 온 프레임은 가장 최근 것 하나만 남겼다가 바로 처리', () async {
    final det = _Gated();
    final src = _FakeSource(jpeg);
    final p = CameraPipeline(
        settings: settings,
        analyzer: _Ai(),
        sourceFactory: (_) => src,
        detectorFactory: () => det);
    await p.open(SourceKind.camera);
    src.emit(); // 100: 처리 시작(막힘)
    await _until(() => det.seen.length == 1);
    src
      ..emit() // 200: 대기
      ..emit(); // 300: 대기 자리를 차지 → 200은 버림
    await Future<void>.delayed(const Duration(milliseconds: 20));
    det.release();
    await _until(() => det.seen.length == 2);
    expect(det.seen, [100, 300]);
    det.release();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(det.seen, [100, 300], reason: '대기 프레임이 없으면 더 처리하지 않음');
    p.dispose();
  });

  test('카메라가 렌즈 화각을 알려 주면 자이로 환산에 그 값을 씀', () async {
    final src = _FakeSource(jpeg)..lensFov = const Size(0.8, 1.3);
    final gyro = GyroCameraMotion();
    settings.gyro = true;
    final p = CameraPipeline(
        settings: settings,
        analyzer: _Ai(),
        sourceFactory: (_) => src,
        detectorFactory: _NoBox.new,
        motionFactory: () => gyro);
    await p.open(SourceKind.camera);
    expect(gyro.lensFovX, 0.8);
    expect(gyro.radToY, 1 / 1.3);
    p.dispose();
  });

  test('AI 점검: 결과에 분석한 사진이 함께 오고 콜백 호출', () async {
    final ai = _Ai();
    final src = _FakeSource(jpeg);
    final p = CameraPipeline(
        settings: settings,
        analyzer: ai,
        sourceFactory: (_) => src,
        detectorFactory: _OneBox.new);
    final results = <AiState>[];
    p.onAiResult = results.add;
    await p.open(SourceKind.camera);
    await p.runAi();
    expect(results.single.report!.hazards.single.severity, Severity.high);
    expect(results.single.jpeg, jpeg);
    expect(results.single.auto, isFalse);
    expect(p.ai.value, same(results.single));
    p.dispose();
  });

  test('학습 데이터 모으기: 켜면 설비 위치를 요청해 사진과 함께 저장', () async {
    final src = _FakeSource(jpeg);
    final out = Directory('${tmp.path}/dev');
    settings.collectEquipment = true;
    final p = CameraPipeline(
        settings: settings,
        analyzer: FakeHazardAnalyzer(),
        sourceFactory: (_) => src,
        detectorFactory: _OneBox.new,
        logDir: () async => out);
    await p.open(SourceKind.camera);
    await p.runAi();
    expect(
        p.ai.value!.report!.equipment.map((e) => e.label), ['valve', 'pipe']);
    await p.collecting;
    expect(
        Directory('${out.path}/equipment_dataset/labels')
            .listSync()
            .single
            .path,
        endsWith('.txt'));
    p.dispose();
  });

  test('자동 점검: 새 ID가 나오면 한 번, 쿨다운 안에는 또 안 함', () async {
    final ai = _Ai();
    final src = _FakeSource(jpeg);
    final det = _OneBox();
    settings.autoAiCooldownSec = 60;
    final p = CameraPipeline(
        settings: settings,
        analyzer: ai,
        sourceFactory: (_) => src,
        detectorFactory: () => det)
      ..autoAi = true;
    final results = <AiState>[];
    p.onAiResult = results.add;
    await p.open(SourceKind.camera);
    for (var i = 0; i < 5; i++) {
      src.emit();
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await _until(() => results.isNotEmpty);
    expect(results.single.auto, isTrue);

    // 완전히 다른 곳에 새 물체(새 ID) → 쿨다운 60초라 다시 안 함
    det.box = const Rect.fromLTWH(0.7, 0.7, 0.1, 0.1);
    for (var i = 0; i < 8; i++) {
      src.emit();
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(ai.calls, 1);
    p.dispose();
  });

  test('AI가 실패해도 찍은 사진은 결과에 남음(사진만 저장용)', () async {
    final p = CameraPipeline(
        settings: settings,
        analyzer: _FailAi(),
        sourceFactory: (_) => _FakeSource(jpeg),
        detectorFactory: _OneBox.new);
    await p.open(SourceKind.camera);
    await p.runAi();
    expect(p.ai.value!.error, contains('인터넷'));
    expect(p.ai.value!.jpeg, jpeg);
    p.dispose();
  });

  test('키 없음 → 오류 상태(사진 안 찍음)', () async {
    final p = CameraPipeline(
        settings: settings,
        analyzer: _Ai(reason: 'GEMINI_API_KEY 없음'),
        sourceFactory: (_) => _FakeSource(jpeg),
        detectorFactory: _OneBox.new);
    await p.open(SourceKind.camera);
    await p.runAi();
    expect(p.ai.value!.error, 'GEMINI_API_KEY 없음');
    expect(p.ai.value!.jpeg, isNull);
    p.dispose();
  });

  test('권한 거부 → 현장용 안내 문구, 설정 바꾸면 카메라 다시 엶', () async {
    var made = 0;
    final p = CameraPipeline(
        settings: settings,
        analyzer: _Ai(),
        sourceFactory: (_) => made++ == 0
            ? _FakeSource(jpeg,
                failWith: CameraException('CameraAccessDenied', 'denied'))
            : _FakeSource(jpeg),
        detectorFactory: _OneBox.new);
    await p.open(SourceKind.camera);
    expect(p.error, contains('카메라 권한이 필요합니다'));
    expect(p.source, isNull);

    await settings.update((s) => s.preset = ResolutionPreset.medium);
    await _until(() => p.source != null);
    expect(made, 2);
    expect(p.error, isNull);
    p.dispose();
  });

  test('절전: 가만히 3초 지나면 초당 2번만 처리, 돌리면 바로 전부 처리', () async {
    final src = _FakeSource(jpeg);
    final gyro = GyroCameraMotion(fovX: 1.0, fovY: 1.0);
    final det = _Counting();
    settings.gyro = true;
    final p = CameraPipeline(
        settings: settings,
        analyzer: _Ai(),
        sourceFactory: (_) => src,
        detectorFactory: () => det,
        motionFactory: () => gyro);
    await p.open(SourceKind.camera);
    Future<void> frames(int n) async {
      for (var i = 0; i < n; i++) {
        src.emit(); // 프레임 간격 100ms(10FPS)
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }

    await frames(60); // 6초 정지: 앞 3초는 전부(≈30), 뒤 3초는 0.5초마다(≈6)
    expect(det.calls, inInclusiveRange(30, 40));
    expect(p.eco, isTrue);

    gyro.addSample(src.t, 0, 0.3); // 돌리기 시작
    final before = det.calls;
    await frames(10);
    expect(det.calls - before, 10);
    expect(p.eco, isFalse);

    // 꺼 두면(카메라 테스트 화면) 가만히 있어도 전부 처리
    gyro.addSample(src.t, 0, 0);
    p.ecoEnabled = false;
    final before2 = det.calls;
    await frames(50);
    expect(det.calls - before2, 50);
    p.dispose();
  });

  test('절전: 탐지 박스 수가 1↔2로 깜빡여도 켜지고, 처음 보는 물체가 나타나면 다시 전부 처리', () async {
    final src = _FakeSource(jpeg);
    final det = _Flicker();
    settings.gyro = true;
    final p = CameraPipeline(
        settings: settings,
        analyzer: _Ai(),
        sourceFactory: (_) => src,
        detectorFactory: () => det,
        motionFactory: () => GyroCameraMotion(fovX: 1.0, fovY: 1.0));
    await p.open(SourceKind.camera);
    Future<void> frames(int n) async {
      for (var i = 0; i < n; i++) {
        src.emit();
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }

    // 실기기처럼 같은 물체 하나 + 잠깐씩 나오는 박스(번갈아 나와 ID는 안 붙음)
    await frames(60);
    expect(p.eco, isTrue, reason: '박스 수가 깜빡여도 새 물체가 없으면 절전');
    expect(det.calls, inInclusiveRange(30, 40));

    // 새 물체가 계속 보임 → 절전 중엔 초당 2번 처리라 3번 잡혀 ID가 붙기까지 ~1.5초 → 그 뒤 전부 처리
    // (폰을 움직이면 자이로로 바로 깸)
    det.second = true;
    await frames(25);
    expect(p.eco, isFalse);
    p.dispose();
  });

  test('AI 사진을 찍은 뒤 폰을 돌리면 위험 표시가 그만큼 따라 움직임(자이로)', () async {
    final src = _FakeSource(jpeg);
    final gyro = GyroCameraMotion(fovX: 1.0, fovY: 1.0);
    settings.gyro = true;
    final p = CameraPipeline(
        settings: settings,
        analyzer: _Ai(),
        sourceFactory: (_) => src,
        detectorFactory: _OneBox.new,
        motionFactory: () => gyro);
    await p.open(SourceKind.camera);
    await p.runAi();
    expect(p.hazardShift.value, Offset.zero);

    // 찍은 뒤 1초 동안 왼쪽으로 0.3rad 회전(ω_y=0.3) → 화면 속 물체는 오른쪽으로 0.3(화각 1rad)
    final t0 = DateTime.now().millisecondsSinceEpoch;
    for (var t = 20; t <= 1000; t += 20) {
      gyro.addSample(t0 + t, 0, 0.3);
    }
    src.t = t0 + 1000;
    src.emit(); // 프레임 시각 = t0 + 1100
    await _until(() => p.hazardShift.value.dx > 0.2);
    expect(p.hazardShift.value.dx, closeTo(0.3, 0.05));

    p.clearAi();
    expect(p.hazardShift.value, Offset.zero);
    p.dispose();
  });

  test('위험 박스 화면 좌표: cover 매핑 + 이동량', () {
    // 9:16 스냅샷을 같은 비율 화면에 → 그대로, shift 0.1이면 화면 폭의 10% 오른쪽
    final r = HazardBoxPainter.toView(const Rect.fromLTRB(0.2, 0.2, 0.4, 0.4),
        const Size(720, 1280), const Size(360, 640), const Offset(0.1, 0));
    expect(r.left, closeTo(0.3 * 360, 1e-6));
    expect(r.top, closeTo(0.2 * 640, 1e-6));
  });

  test('화면 밖으로 나간 위험은 가장자리 화살표로 방향 표시', () {
    const view = Size(360, 640);
    // 조금이라도 보이면 화살표 없음
    expect(
        HazardBoxPainter.offscreenArrow(
            const Rect.fromLTRB(340, 300, 400, 340), view),
        isNull);
    // 오른쪽으로 완전히 나감 → 오른쪽 가장자리 안쪽(폭 − 28), 방향 0
    final (at, angle) = HazardBoxPainter.offscreenArrow(
        const Rect.fromLTRB(400, 300, 460, 340), view)!;
    expect(at.dx, closeTo(360 - 28, 1e-6));
    expect(at.dy, closeTo(320, 1e-6));
    expect(angle, closeTo(0, 1e-6));
    // 왼쪽 위로 나감 → 화면 안쪽, 왼쪽 위를 향함
    final (at2, angle2) = HazardBoxPainter.offscreenArrow(
        const Rect.fromLTRB(-300, -500, -200, -400), view)!;
    expect((Offset.zero & view).contains(at2), isTrue);
    expect(angle2, lessThan(-math.pi / 2));

    // 그리기까지 오류 없이(화면 밖 위험 + 화면 안 위험)
    final report = HazardReport(
        summary: '',
        hazards: [
          Hazard(
              type: '누수',
              description: '',
              severity: Severity.high,
              action: '',
              box: const Rect.fromLTRB(0.4, 0.4, 0.6, 0.6)),
          Hazard(
              type: '전선',
              description: '',
              severity: Severity.medium,
              action: '',
              box: const Rect.fromLTRB(0.1, 0.1, 0.2, 0.2)),
        ],
        elapsedMs: 0,
        imageSize: const Size(720, 1280));
    for (final shift in const [Offset(1.5, 0), Offset.zero]) {
      final rec = PictureRecorder();
      HazardBoxPainter(report, shift: shift).paint(Canvas(rec), view);
      rec.endRecording().dispose();
    }
  });

  test('밝기: Y 평면 평균(어두움 판정용)', () {
    final dark = Uint8List(1000)..fillRange(0, 1000, 20);
    final bright = Uint8List(1000)..fillRange(0, 1000, 180);
    expect(CameraPipeline.meanLuma(dark, 1000, step: 7), 20);
    expect(CameraPipeline.meanLuma(bright, 1000, step: 7), 180);
    expect(CameraPipeline.meanLuma(Uint8List(0), 1000), isNull);
  });

  test('흔들리는 중이면 멈출 때까지 기다렸다 찍음(최대 0.7초)', () async {
    final src = _FakeSource(jpeg);
    final gyro = GyroCameraMotion();
    settings.gyro = true;
    final p = CameraPipeline(
        settings: settings,
        analyzer: _Ai(),
        sourceFactory: (_) => src,
        detectorFactory: _OneBox.new,
        motionFactory: () => gyro);
    await p.open(SourceKind.camera);
    gyro.addSample(DateTime.now().millisecondsSinceEpoch, 0, 1.0); // 빠르게 돌리는 중
    // 0.2초 뒤 멈춤
    Timer(const Duration(milliseconds: 200),
        () => gyro.addSample(DateTime.now().millisecondsSinceEpoch, 0, 0));
    final sw = Stopwatch()..start();
    await p.runAi();
    expect(sw.elapsedMilliseconds, inInclusiveRange(150, 650));
    expect(p.ai.value!.report, isNotNull);
    p.dispose();
  });

  test('위험이 물체(트랙) 안에 있으면 물체가 움직일 때 표시도 따라감(자이로 없이)', () async {
    final src = _FakeSource(jpeg);
    final det = _OneBox(); // (0.3,0.3)~(0.5,0.5)
    final p = CameraPipeline(
        settings: settings, // 자이로 끔
        analyzer: _BoxAi(), // 위험 박스 (0.32,0.32)~(0.42,0.42): 트랙 안
        sourceFactory: (_) => src,
        detectorFactory: () => det);
    await p.open(SourceKind.camera);
    for (var i = 0; i < 5; i++) {
      src.emit(); // ID 확정
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await _until(() => p.detections.value.firstOrNull?.trackingId != null);
    await p.runAi();
    expect(p.hazardAnchored.value.keys, [0]);

    // 물체가 오른쪽으로 0.1 이동(조금씩 옮겨 같은 ID 유지)
    for (var k = 1; k <= 4; k++) {
      det.box = Rect.fromLTWH(0.3 + 0.025 * k, 0.3, 0.2, 0.2);
      src.emit();
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await _until(() => p.hazardAnchored.value[0]!.left > 0.38);
    expect(p.hazardAnchored.value[0]!.left, closeTo(0.42, 0.03));
    p.clearAi();
    expect(p.hazardAnchored.value, isEmpty);
    p.dispose();
  });

  test('물체가 안 잡혀도 폰을 충분히 돌리고 멈추면 "새 장면"으로 자동 점검', () async {
    final src = _FakeSource(jpeg);
    final gyro = GyroCameraMotion(fovX: 1.0, fovY: 1.0);
    final ai = _Ai();
    settings
      ..gyro = true
      ..autoAiCooldownSec = 0;
    final p = CameraPipeline(
        settings: settings,
        analyzer: ai,
        sourceFactory: (_) => src,
        detectorFactory: _NoBox.new, // 기계실처럼 ML Kit이 아무것도 못 잡는 상황
        motionFactory: () => gyro)
      ..autoAi = true;
    await p.open(SourceKind.camera);
    var t = DateTime.now().millisecondsSinceEpoch;
    Future<void> frame() async {
      src.t = t;
      src.emit();
      await Future<void>.delayed(const Duration(milliseconds: 15));
    }

    // 가만히 있으면 자동 점검 안 함
    for (var i = 0; i < 3; i++) {
      gyro.addSample(t += 100, 0, 0);
      await frame();
    }
    expect(ai.calls, 0);

    // 1초 동안 0.8rad/s로 돌림(화면 0.8 이동) → 도는 중에는 안 함
    for (var i = 0; i < 10; i++) {
      gyro.addSample(t += 100, 0, 0.8);
      await frame();
    }
    expect(ai.calls, 0);

    // 멈추면 새 장면 → 한 번 점검, 그 뒤 가만히 있으면 더 안 함
    for (var i = 0; i < 5; i++) {
      gyro.addSample(t += 100, 0, 0);
      await frame();
    }
    await _until(() => ai.calls == 1);
    for (var i = 0; i < 5; i++) {
      gyro.addSample(t += 100, 0, 0);
      await frame();
    }
    expect(ai.calls, 1);
    p.dispose();
  });

  test('어두우면 노출 +1EV, 밝아지면 원래대로(어두움 안내도 같이)', () async {
    final src = _FakeSource(jpeg);
    final p = CameraPipeline(
        settings: settings,
        analyzer: _Ai(),
        sourceFactory: (_) => src,
        detectorFactory: _NoBox.new);
    await p.open(SourceKind.camera);
    for (var i = 0; i < 6; i++) {
      src.emitLuma(20);
      await Future<void>.delayed(const Duration(milliseconds: 15));
    }
    await _until(() => src.ev == 1.0);
    expect(p.isDark.value, isTrue);
    // 보정으로 밝아진 화면(2배)을 다시 "밝음"으로 착각해 내렸다 올렸다 하지 않음
    for (var i = 0; i < 12; i++) {
      src.emitLuma(90); // 예전 방식이면 90 > 70 → 밝음으로 뒤집힘
      await Future<void>.delayed(const Duration(milliseconds: 15));
    }
    expect(p.isDark.value, isTrue);
    expect(src.ev, 1.0);
    // 설정을 끄면 바로 원래대로, 다시 켜면 다시 올림
    await settings.update((s) => s.autoExposure = false);
    await _until(() => src.ev == 0);
    await settings.update((s) => s.autoExposure = true);
    await _until(() => src.ev == 1.0);
    for (var i = 0; i < 6; i++) {
      src.emitLuma(200);
      await Future<void>.delayed(const Duration(milliseconds: 15));
    }
    await _until(() => src.ev == 0);
    expect(p.isDark.value, isFalse);

    // 꺼 두면 어두워도 노출은 그대로
    await settings.update((s) => s.autoExposure = false);
    for (var i = 0; i < 6; i++) {
      src.emitLuma(20);
      await Future<void>.delayed(const Duration(milliseconds: 15));
    }
    await _until(() => p.isDark.value);
    expect(src.ev, 0);
    p.dispose();
  });

  test('손전등·줌은 카메라로 전달', () async {
    final src = _FakeSource(jpeg);
    final p = CameraPipeline(
        settings: settings,
        analyzer: _Ai(),
        sourceFactory: (_) => src,
        detectorFactory: _OneBox.new);
    await p.open(SourceKind.camera);
    await p.setTorch(true);
    await p.setZoom(2);
    expect(src.torchOn, isTrue);
    expect(src.zoom, 2);
    await p.close();
    expect(src.disposed, isTrue);
    p.dispose();
  });

  testWidgets('위험 박스를 탭하면 [무시] [완료], 누르면 알림 · 처리된 위험은 다시 안 골라짐', (t) async {
    t.view
      ..physicalSize = const Size(360, 640)
      ..devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final src = _FakeSource(jpeg);
    final p = CameraPipeline(
        settings: settings,
        analyzer: _BoxAi(),
        sourceFactory: (_) => src,
        detectorFactory: _NoBox.new);
    await t.runAsync(() async {
      await p.open(SourceKind.camera);
      await p.runAi();
    });
    final actions = <(int, HazardStatus, String)>[];
    await t.pumpWidget(MaterialApp(
        home: Scaffold(
            body: CameraView(
                pipeline: p,
                onHazardAction: (i, s, by) => actions.add((i, s, by))))));
    // 사진 720x1280 → 화면 360x640(0.5배), 위험 box_2d [320,320,420,420] → 화면 (115~151, 205~269)
    const onHazard = Offset(133, 237);
    expect(find.text('완료'), findsNothing);
    await t.tapAt(onHazard);
    await t.pump();
    expect(find.text('완료'), findsOneWidget);
    expect(find.text('무시'), findsOneWidget);

    await t.tap(find.text('완료'));
    await t.pump();
    expect(actions, [(0, HazardStatus.resolved, 'tap')]);
    expect(find.text('완료'), findsNothing, reason: '누르면 버튼 닫힘');

    // 다른 곳을 탭하면 닫힘
    await t.tapAt(onHazard);
    await t.pump();
    expect(find.text('무시'), findsOneWidget);
    await t.tapAt(const Offset(300, 100));
    await t.pump();
    expect(find.text('무시'), findsNothing);

    // 화면이 처리 상태를 기록하면(점검 화면이 하는 일) 그 위험은 다시 안 골라짐 → 탭은 초점으로
    p.ai.value!.report!.hazards[0].setStatus(HazardStatus.resolved, by: 'tap');
    p.markHazardsChanged();
    await t.pump();
    await t.tapAt(onHazard);
    await t.pump();
    expect(find.text('무시'), findsNothing);
    await t.pump(const Duration(seconds: 1)); // 초점 표시 타이머 정리

    await t.pumpWidget(const SizedBox());
    p.dispose();
  });

  test('손 인식: 처리 안 된 위험 박스가 있을 때만 돌고, 다 처리하면 멈춤 · 실패하면 이번 실행 동안 끔', () async {
    final src = _FakeSource(jpeg);
    final hands = _FakeHands();
    final p = CameraPipeline(
        settings: settings,
        analyzer: _BoxAi(),
        sourceFactory: (_) => src,
        detectorFactory: _NoBox.new,
        handFactory: () => hands);
    await p.open(SourceKind.camera);
    Future<void> frames(int n) async {
      for (var i = 0; i < n; i++) {
        src.emit(); // 100ms 간격 → 손 인식 최소 간격(66ms)보다 길어 매번
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }

    await frames(4);
    expect(hands.calls, 0, reason: 'AI 결과(위험 박스)가 없으면 안 돎');
    await p.runAi();
    hands.tip = const Offset(0.37, 0.37);
    await frames(5);
    expect(hands.calls, 5);
    expect(p.hand.value?.pointer?.tip, const Offset(0.37, 0.37));

    p.ai.value!.report!.hazards.single
        .setStatus(HazardStatus.resolved, by: 'tap');
    await frames(3);
    expect(hands.calls, 5, reason: '누를 위험이 없으면 멈춤');
    expect(p.hand.value, isNull);

    p.ai.value!.report!.hazards.single.setStatus(HazardStatus.open);
    settings.handControl = false;
    await frames(3);
    expect(hands.calls, 5, reason: '설정에서 끄면 안 돎');
    settings.handControl = true;

    hands.failWith = StateError('모델 없음');
    await frames(4);
    expect(hands.calls, 6, reason: '한 번 실패하면 이번 실행 동안 끄고 화면 탭만');
    expect(p.hand.value, isNull);

    await p.close();
    expect(hands.closed, isTrue);
    p.dispose();
  });

  testWidgets('손가락: 위험 박스 위에 머무르면 버튼, [완료] 위에 1초 머무르면 누름', (t) async {
    t.view
      ..physicalSize = const Size(360, 640)
      ..devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final src = _FakeSource(jpeg);
    final p = CameraPipeline(
        settings: settings,
        analyzer: _BoxAi(),
        sourceFactory: (_) => src,
        detectorFactory: _NoBox.new,
        handFactory: _FakeHands.new);
    await t.runAsync(() async {
      await p.open(SourceKind.camera);
      await p.runAi();
    });
    final actions = <(int, HazardStatus, String)>[];
    await t.pumpWidget(MaterialApp(
        home: Scaffold(
            body: CameraView(
                pipeline: p,
                onHazardAction: (i, s, by) => actions.add((i, s, by))))));
    HandFrame at(int ms, Offset tip) => HandFrame(ms, [_handAt(tip)]);

    // 위험 박스(화면 115~151, 205~269) 가운데 = 0.37, 0.37
    for (var ms = 0; ms <= 400; ms += 100) {
      p.hand.value = at(ms, const Offset(0.37, 0.37));
      await t.pump();
    }
    expect(find.text('완료'), findsOneWidget);

    const view = Size(360, 640);
    final rect = HazardBoxPainter.viewRects(p.ai.value!.report!, view)[0]!;
    final done = HazardActionLayout.of(rect, view).done.center;
    final doneN = Offset(done.dx / view.width, done.dy / view.height);
    for (var ms = 500; ms <= 2500 && actions.isEmpty; ms += 100) {
      p.hand.value = at(ms, doneN);
      await t.pump();
    }
    expect(actions, [(0, HazardStatus.resolved, 'hand')]);
    expect(find.text('완료'), findsNothing);

    // 손이 사라지면(손 인식 멈춤) 커서도 사라짐
    p.hand.value = null;
    await t.pump();
    await t.pumpWidget(const SizedBox());
    p.dispose();
  });
}

HandLandmarks _handAt(Offset tip) => HandLandmarks([
      for (var i = 0; i < 21; i++)
        i == HandLandmarks.indexTip ? tip : const Offset(0.5, 0.95)
    ]);

/// 가짜 손 인식: 정해 둔 검지 끝(없으면 손 없음)을 돌려줌
class _FakeHands implements HandTracker {
  Offset? tip;
  int calls = 0;
  bool closed = false;
  Object? failWith;

  @override
  Future<List<HandLandmarks>> detect(Frame f) async {
    calls++;
    if (failWith case final e?) throw e;
    final t = tip;
    return t == null ? const [] : [_handAt(t)];
  }

  @override
  Future<void> close() async => closed = true;
}
