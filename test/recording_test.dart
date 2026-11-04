import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:facility_camera/analysis/hazard.dart';
import 'package:facility_camera/analysis/hazard_analyzer.dart';
import 'package:facility_camera/camera/camera_pipeline.dart';
import 'package:facility_camera/camera/camera_recorder.dart';
import 'package:facility_camera/core/frame.dart';
import 'package:facility_camera/data/app_settings.dart';
import 'package:facility_camera/detection/detector.dart';
import 'package:facility_camera/motion/camera_motion.dart';
import 'package:facility_camera/sources/frame_source.dart';
import 'package:facility_camera/sources/recording_frame_source.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// 시험용 녹화(카메라 원본 + 자이로)와 재생(녹화를 진짜 카메라처럼 흘림)
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const ch = MethodChannel('facility_camera/recorder');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory tmp;
  final saved = <String>[];
  Completer<void>? gate; // 있으면 저장이 끝나지 않고 대기(밀림 시험)

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('fc_rec_');
    saved.clear();
    gate = null;
    messenger.setMockMethodCallHandler(ch, (call) async {
      final a = call.arguments as Map;
      switch (call.method) {
        case 'saveJpeg':
          await gate?.future;
          saved.add(a['path'] as String);
          return 1000;
        case 'loadNv21': // 4x2 화면
          return {'bytes': Uint8List(12), 'w': 4, 'h': 2};
        case 'uprightJpeg':
          return Uint8List.fromList([1, 2, 3]);
      }
      return null;
    });
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(ch, null);
    tmp.deleteSync(recursive: true);
  });

  Frame nv21(int ms) => Frame.raw(
      timestampMs: ms,
      format: FrameFormat.nv21,
      bytes: Uint8List(12),
      rawSize: const Size(4, 2),
      rotationDegrees: 90,
      bytesPerRow: 4,
      uprightSize: const Size(2, 4));

  List<Map<String, dynamic>> lines(File f) => [
        for (final l in f.readAsLinesSync())
          if (l.trim().isNotEmpty) jsonDecode(l) as Map<String, dynamic>
      ];

  test('녹화: 카메라 원본을 JPEG로, 자이로·탐지와 함께 분석 로그 형식으로 · 요약', () async {
    final r = CameraRecorder(Directory('${tmp.path}/r1'))
      ..start({
        'v': 1,
        'lensFov': [0.8, 1.3]
      });
    r.gyro(990, 0.5, 0.5); // 첫 화면 전 자이로는 버림(시작 시각 전)
    r.addFrame(nv21(1000));
    r.gyro(1010, 0.1, -0.2);
    r.detections(1000, [
      const Detection(
          trackingId: null,
          box: Rect.fromLTRB(0.1, 0.2, 0.3, 0.4),
          label: '',
          confidence: 0.5)
    ]);
    r.addFrame(nv21(1066));
    r.addFrame(const Frame.file(
        timestampMs: 1100, filePath: 'x.jpg', uprightSize: Size(1, 1)));
    await r.stop();

    expect(saved,
        ['${tmp.path}/r1/frames/1000.jpg', '${tmp.path}/r1/frames/1066.jpg']);
    final log = lines(File('${tmp.path}/r1/log.jsonl'));
    expect(log.first['k'], 'meta');
    expect(log.first['rotation'], 90);
    expect(log.first['rawW'], 4);
    expect(log.first['lensFov'], [0.8, 1.3]);
    expect(log.where((m) => m['k'] == 'img').map((m) => m['f']),
        ['frames/1000.jpg', 'frames/1066.jpg']);
    expect(log.where((m) => m['k'] == 'g').single['t'], 1010);
    expect(log.where((m) => m['k'] == 'f').single['d'][0][0], 0.1);
    final sum =
        jsonDecode(File('${tmp.path}/r1/summary.json').readAsStringSync());
    expect(sum['frames'], 2);
    expect(sum['seconds'], closeTo(0.066, 1e-9));

    final list = await Recording.list(tmp);
    expect(list.single.frames, 2);
    expect(list.single.name, 'r1');
  });

  test('녹화: 저장이 밀리면(2장 대기) 그 장은 건너뛰고 셈', () async {
    gate = Completer<void>();
    final r = CameraRecorder(Directory('${tmp.path}/r2'))..start({});
    for (var i = 0; i < 4; i++) {
      r.addFrame(nv21(1000 + i * 66));
    }
    expect(r.dropped, 2);
    gate!.complete();
    await r.stop();
    expect(r.frames, 2);
  });

  /// 자이로 2개 → 화면 → 자이로·줌 → 화면 순서의 녹화 폴더
  Directory writeRecording() {
    final d = Directory('${tmp.path}/2026-11-04T101530')..createSync();
    File('${d.path}/log.jsonl').writeAsStringSync([
      {
        'k': 'meta',
        'rotation': 90,
        'rawW': 4,
        'rawH': 2,
        'lensFov': [0.8, 1.3],
        'zoom': 1
      },
      {'k': 'g', 't': 990, 'x': 0.3, 'y': -0.2},
      {'k': 'g', 't': 1000, 'x': 0.3, 'y': -0.2},
      {'k': 'img', 't': 1000, 'f': 'frames/1000.jpg'},
      {'k': 'g', 't': 1020, 'x': 0.6, 'y': 0},
      {'k': 'z', 't': 1030, 'z': 2.0},
      {'k': 'img', 't': 1040, 'f': 'frames/1040.jpg'},
    ].map(jsonEncode).join('\n'));
    return d;
  }

  test('재생: 원래 간격대로 카메라 같은 NV21 화면 + 그 전까지의 자이로·줌을 먼저', () async {
    final src = RecordingFrameSource(writeRecording(), loop: false);
    final events = <String>[];
    final frames = <Frame>[];
    final gyros = <int>[];
    src.gyro.listen((g) {
      events.add('g');
      gyros.add(g.$1);
    });
    src.zooms.listen((z) => events.add('z$z'));
    final done = Completer<void>();
    src.frames.listen((f) {
      events.add('f');
      frames.add(f);
      if (frames.length == 2) done.complete();
    });
    await src.start();
    expect(src.aspectRatio.value, 0.5); // 4x2 센서를 90° 세움 → 2:4
    expect(src.lensFov, const Size(0.8, 1.3));
    await done.future.timeout(const Duration(seconds: 2));

    expect(events, ['g', 'g', 'f', 'g', 'z2.0', 'f']);
    expect(frames[1].timestampMs - frames[0].timestampMs, 40); // 원래 간격
    expect(gyros.first, frames[0].timestampMs - 10); // 자이로도 같은 만큼 옮김
    expect(frames[0].format, FrameFormat.nv21);
    expect(frames[0].rotationDegrees, 90);
    expect(frames[0].uprightSize, const Size(2, 4));
    expect(await src.snapshotJpeg(), [1, 2, 3]); // 지금 화면을 똑바로 세운 AI 사진
    await src.dispose();
  });

  test('파이프라인: 녹화 재생이면 자이로 센서 대신 녹화된 자이로로 추적 · 녹화 시작/멈춤', () async {
    final settings = AppSettings(File('${tmp.path}/s.json'))..gyro = true;
    final motion = GyroCameraMotion();
    // 반복 없이 한 번만(확인하는 순간 처음부터 다시 돌아 자이로가 바뀌지 않게)
    final src = RecordingFrameSource(writeRecording(), loop: false);
    final p = CameraPipeline(
        settings: settings,
        analyzer: _NoAi(),
        sourceFactory: (_) => src,
        motionFactory: () => motion,
        detectorFactory: _OneBox.new,
        logDir: () async => tmp)
      ..ecoEnabled = false;
    final got = Completer<void>();
    var n = 0;
    src.frames.listen((_) {
      if (++n == 2) got.complete();
    });
    await p.open(SourceKind.recording);
    expect(p.source, isA<RecordingFrameSource>());
    await got.future.timeout(const Duration(seconds: 2));
    expect(motion.lastRate.dx, closeTo(0.6, 0.05)); // 녹화된 마지막 자이로
    expect(motion.zoom, 2.0);
    await p.startRecording(); // 재생 중에는 녹화 안 함
    expect(p.recording.value, isNull);
    p.dispose();

    // 카메라(가짜 NV21)에서는 녹화가 되고, 멈추면 요약이 남음
    final cam = _NvSource();
    final p2 = CameraPipeline(
        settings: settings..gyro = false,
        analyzer: _NoAi(),
        sourceFactory: (_) => cam,
        detectorFactory: _OneBox.new,
        logDir: () async => tmp);
    await p2.open(SourceKind.camera);
    await p2.startRecording();
    expect(p2.recording.value, isNotNull);
    for (var i = 0; i < 3; i++) {
      cam.emit(nv21(5000 + i * 66));
      await Future<void>.delayed(Duration.zero);
    }
    final r = await p2.stopRecording();
    expect(r!.frames, 3);
    expect(p2.recording.value, isNull);
    expect(p2.lastRecording, same(r));
    expect(r.dir.parent.path, '${tmp.path}/recordings');
    p2.dispose();
  });
}

class _OneBox implements Detector {
  @override
  Future<List<Detection>> detect(Frame f) async => const [
        Detection(
            trackingId: null,
            box: Rect.fromLTWH(0.3, 0.3, 0.2, 0.2),
            label: '',
            confidence: 0)
      ];
  @override
  Future<void> close() async {}
}

class _NoAi implements HazardAnalyzer {
  @override
  String? get unavailableReason => 'test';
  @override
  String get description => 'none';
  @override
  Future<HazardReport> analyze(Uint8List jpeg,
          {String? place, bool equipment = false}) =>
      throw UnimplementedError();
}

/// 테스트가 NV21 화면을 직접 넣는 가짜 카메라
class _NvSource implements FrameSource {
  final _out = StreamController<Frame>.broadcast();
  void emit(Frame f) => _out.add(f);
  @override
  String get name => 'nv';
  @override
  ValueListenable<double> get aspectRatio => ValueNotifier(0.5);
  @override
  Stream<Frame> get frames => _out.stream;
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() => _out.close();
  @override
  Future<Uint8List> snapshotJpeg() async => Uint8List(0);
  @override
  Widget buildPreview(BuildContext context) => const SizedBox();
  @override
  CameraControls? get controls => null;
}
