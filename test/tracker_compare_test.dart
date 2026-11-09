import 'dart:io';
import 'package:facility_camera/detection/detector.dart';
import 'package:facility_camera/detection/tracking_detector.dart';
import 'package:facility_camera/motion/camera_motion.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/replay.dart';
import 'support/scenario.dart';
import 'tracking_scenarios_test.dart' show scenarios;

/// 추적기 설정 비교(새 알고리즘을 넣기 전후를 숫자로). 평소에는 건너뜀:
///   flutter test test/tracker_compare_test.dart --dart-define=COMPARE=true -r expanded
/// - 가상 장면 12종: 카메라가 도는 장면은 실사용처럼 자이로를 켜고. ID 재현율(같은 물체가 같은 번호로 유지된 비율)·번호 바뀜·오탐 ID
/// - 실제 폰 기록(build/analysis_logs/**/*.jsonl, build/recordings/*/log.jsonl): 새 번호/분(적을수록 좋음)
const _run = bool.fromEnvironment('COMPARE');

typedef Make = TrackingDetector Function(Detector d, CameraMotion? m);

/// 기준 = 11/09 이전 설정(OCR·C-BIoU 끔). 새 알고리즘을 시험할 때 여기에 한 줄씩 더함
final variants = <String, Make>{
  '이전(11/08까지)': (d, m) =>
      TrackingDetector(d, motion: m, bufferScale: 0, ocr: false),
  'OCR만': (d, m) => TrackingDetector(d, motion: m, bufferScale: 0),
  'C-BIoU 0.3만': (d, m) => TrackingDetector(d, motion: m, ocr: false),
  'C-BIoU 0.5+OCR': (d, m) => TrackingDetector(d, motion: m, bufferScale: 0.5),
  '지금(OCR→C-BIoU 0.3)': (d, m) => TrackingDetector(d, motion: m),
};

void main() {
  test('가상 장면 12종 × 설정', () async {
    final rows = <String, List<MotMetrics>>{};
    for (final s in scenarios) {
      final line = StringBuffer(s.name.split(' ').first.padRight(3));
      for (final e in variants.entries) {
        final m = await evaluate(s, e.value, gyro: s.cameraShift != null);
        (rows[e.key] ??= []).add(m);
        line.write(' | ${e.key}: ${(m.idRecall * 100).round()}% '
            'IDSW ${m.idSwitches} 오탐 ${m.falseIds}');
      }
      // ignore: avoid_print
      print(line);
    }
    // ignore: avoid_print
    print('\n=== 설정별 요약(ID 재현율 평균·최저, 번호 바뀜 합, 오탐 ID 합) ===');
    for (final e in rows.entries) {
      final r = [for (final m in e.value) m.idRecall];
      final avg = r.reduce((a, b) => a + b) / r.length;
      final min = r.reduce((a, b) => a < b ? a : b);
      final sw = e.value.fold<int>(0, (a, m) => a + m.idSwitches);
      final fa = e.value.fold<int>(0, (a, m) => a + m.falseIds);
      // ignore: avoid_print
      print('${e.key.padRight(16)} 평균 ${(avg * 100).toStringAsFixed(1)}% · '
          '최저 ${(min * 100).round()}% · 번호 바뀜 $sw · 오탐 ID $fa');
    }
  }, skip: _run ? false : 'COMPARE=true일 때만');

  test('실제 폰 기록 × 설정(새 번호/분)', () async {
    final logs = [
      ...Directory('build/analysis_logs')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.jsonl')),
      if (Directory('build/recordings').existsSync())
        ...Directory('build/recordings')
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('log.jsonl')),
    ];
    for (final f in logs) {
      final log = ReplayLog.parse(f.readAsLinesSync());
      if (log.frames.length < 30) continue;
      final line =
          StringBuffer('${f.uri.pathSegments.last} (${log.frames.length}프레임)');
      for (final e in variants.entries) {
        final st = await replay(log, make: e.value);
        line.write(' | ${e.key}: ${st.idsPerMin.toStringAsFixed(1)}');
      }
      // ignore: avoid_print
      print(line);
    }
  },
      skip: _run && Directory('build/analysis_logs').existsSync()
          ? false
          : 'COMPARE=true + build/analysis_logs 있을 때만');
}
