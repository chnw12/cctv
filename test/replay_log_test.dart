import 'dart:io';
import 'dart:ui';
import 'package:facility_camera/camera/analysis_log.dart';
import 'package:facility_camera/core/frame.dart';
import 'package:facility_camera/detection/detector.dart';
import 'package:facility_camera/detection/tracking_detector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/replay.dart';

/// 실기기에서 기록한 분석 로그를 추적기에 다시 돌려 설정별로 비교:
///   adb pull /sdcard/Android/data/com.example.facility_camera/files/analysis_logs build/analysis_logs
///   flutter test test/replay_log_test.dart --dart-define=REPLAY_LOG=build/analysis_logs/<파일>.jsonl -r expanded
const _path = String.fromEnvironment('REPLAY_LOG');

void main() {
  test('기록 → 재생: 로그 형식이 앞뒤로 맞고 추적기가 같은 결과를 냄', () async {
    final dir = Directory.systemTemp.createTempSync('fc_log_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final log = AnalysisLog(File('${dir.path}/a.jsonl'))
      ..open({
        'v': 1,
        'lensFov': [0.8, 1.3],
        'zoom': 1.0
      });
    // 물체 하나가 14FPS로 10초 동안 잡힘 + 자이로 50Hz(정지)
    for (var t = 0; t <= 10000; t += 10) {
      if (t % 20 == 0) log.gyro(t, 0.001, -0.002);
      if (t % 70 == 0) {
        log.frame(t, const [
          Detection(
              trackingId: null,
              box: Rect.fromLTWH(0.3, 0.3, 0.2, 0.2),
              label: 'Home good',
              confidence: 0.8)
        ]);
      }
    }
    log.zoom(5000, 2);
    await log.close();

    final parsed =
        ReplayLog.parse(File('${dir.path}/a.jsonl').readAsLinesSync());
    expect(parsed.meta['lensFov'], [0.8, 1.3]);
    expect(parsed.frames, hasLength(143));
    expect(parsed.gyro, hasLength(501));
    expect(parsed.zooms.single, (5000, 2.0));
    expect(parsed.frames.first.boxes.single.left, closeTo(0.3, 1e-4));

    final st = await replay(parsed);
    expect(st.ids, 1, reason: '같은 자리 물체 하나 → ID 하나');
    expect(st.confirmed / st.frames, greaterThan(0.95));
  });

  test('기록한 탐지기 감싸기: 원본 결과를 그대로 적고 그대로 돌려줌', () async {
    final dir = Directory.systemTemp.createTempSync('fc_log_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final log = AnalysisLog(File('${dir.path}/b.jsonl'))..open({'v': 1});
    final d = LoggingDetector(_Two(), log.frame);
    final out = await d.detect(const Frame.file(
        timestampMs: 123, filePath: '', uprightSize: Size(1, 1)));
    await log.close();
    expect(out, hasLength(2));
    final f = ReplayLog.parse(File('${dir.path}/b.jsonl').readAsLinesSync())
        .frames
        .single;
    expect(f.ms, 123);
    expect(f.boxes, hasLength(2));
  });

  test('실기기 로그 재생(REPLAY_LOG 줄 때만)', () async {
    final log = ReplayLog.parse(File(_path).readAsLinesSync());
    final runs = <String, Future<ReplayStats>>{
      '지금 추적기(자이로)': replay(log),
      '지금 추적기(자이로 없이)': replay(log, gyro: false),
      '잃어버린 트랙 2초만 기억(예전 값)': replay(log,
          make: (d, m) => TrackingDetector(d, motion: m, maxMissMs: 2000)),
      'ID 확정 5번(지금 3번)': replay(log,
          make: (d, m) => TrackingDetector(d, motion: m, minHits: 5)),
    };
    // ignore: avoid_print
    print('${log.frames.length}프레임 · 자이로 ${log.gyro.length}개 · ${log.meta}');
    for (final e in runs.entries) {
      // ignore: avoid_print
      print('${e.key.padRight(22)} ${await e.value}');
    }
  }, skip: _path.isEmpty ? 'REPLAY_LOG 없음(실기기 로그를 줄 때만)' : false);
}

class _Two implements Detector {
  @override
  Future<List<Detection>> detect(Frame f) async => const [
        Detection(
            trackingId: null,
            box: Rect.fromLTWH(0.1, 0.1, 0.2, 0.2),
            label: 'a',
            confidence: 0.5),
        Detection(
            trackingId: null,
            box: Rect.fromLTWH(0.5, 0.5, 0.2, 0.2),
            label: 'b',
            confidence: 0.6),
      ];
  @override
  Future<void> close() async {}
}
