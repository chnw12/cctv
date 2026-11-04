import 'dart:convert';
import 'dart:ui';
import 'package:facility_camera/core/frame.dart';
import 'package:facility_camera/detection/detector.dart';
import 'package:facility_camera/detection/tracking_detector.dart';
import 'package:facility_camera/motion/camera_motion.dart';

/// 실기기 분석 로그(lib/camera/analysis_log.dart)를 읽어 추적기를 다시 돌리는 재생기.
/// 정답이 없으므로 "가만히 들고 있을 때 새 ID가 얼마나 생기나" 같은 안정성 지표로 비교합니다.

class ReplayFrame {
  ReplayFrame(this.ms, this.boxes);
  final int ms;
  final List<Rect> boxes;
}

class ReplayLog {
  final meta = <String, Object?>{};
  final frames = <ReplayFrame>[];
  final gyro = <(int, double, double)>[];
  final zooms = <(int, double)>[];

  static ReplayLog parse(Iterable<String> lines) {
    final log = ReplayLog();
    for (final line in lines) {
      if (line.trim().isEmpty) continue;
      final m = jsonDecode(line) as Map<String, dynamic>;
      double n(Object? v) => (v as num).toDouble();
      switch (m['k']) {
        case 'meta':
          log.meta.addAll(m);
        case 'g':
          log.gyro.add((m['t'] as int, n(m['x']), n(m['y'])));
        case 'z':
          log.zooms.add((m['t'] as int, n(m['z'])));
        case 'f':
          log.frames.add(ReplayFrame(m['t'] as int, [
            for (final d in m['d'] as List)
              Rect.fromLTRB(n(d[0]), n(d[1]), n(d[2]), n(d[3]))
          ]));
      }
    }
    return log;
  }
}

class ReplayStats {
  int frames = 0, ids = 0, newIdFrames = 0;
  double seconds = 0, raw = 0, confirmed = 0;

  double get idsPerMin => seconds == 0 ? 0 : ids / seconds * 60;

  @override
  String toString() =>
      '새 ID ${idsPerMin.toStringAsFixed(1).padLeft(5)}/분 (총 $ids) | 프레임당 박스 '
      '${(raw / frames).toStringAsFixed(2)} → 확정 ${(confirmed / frames).toStringAsFixed(2)} | '
      '새 ID 나온 프레임 ${(newIdFrames / frames * 100).toStringAsFixed(1)}%';
}

class _Replay implements Detector {
  _Replay(this.frames);
  final List<ReplayFrame> frames;
  int i = 0;
  @override
  Future<List<Detection>> detect(Frame frame) async => [
        for (final b in frames[i++].boxes)
          Detection(trackingId: null, box: b, label: '', confidence: 0)
      ];
  @override
  Future<void> close() async {}
}

/// 로그를 추적기에 흘림. gyro: 기록된 자이로를 그대로 넣음(렌즈 화각·줌 포함).
/// gyroMap: 자이로 축을 바꿔 넣어 봄(실기기 축 방향 진단), onFrame: 프레임마다 (시각, 새 ID 수, 박스 수, 확정 수),
/// gyroDelayMs: 프레임 시각이 실제 촬영보다 이만큼 늦게 찍힌다고 보고 자이로를 늦춰 넣음(시간 동기 진단)
Future<ReplayStats> replay(ReplayLog log,
    {bool gyro = true,
    (double, double) Function(double wx, double wy)? gyroMap,
    int gyroDelayMs = 0,
    void Function(int ms, int newIds, int boxes, int confirmed)? onFrame,
    TrackingDetector Function(Detector inner, CameraMotion? motion)?
        make}) async {
  GyroCameraMotion? motion;
  if (gyro && log.gyro.isNotEmpty) {
    motion = GyroCameraMotion();
    final fov = log.meta['lensFov'];
    if (fov is List) {
      motion.useLensFov((fov[0] as num).toDouble(), (fov[1] as num).toDouble());
    }
    motion.zoom = ((log.meta['zoom'] as num?) ?? 1).toDouble();
  }
  final tracker = (make ?? (d, m) => TrackingDetector(d, motion: m))(
      _Replay(log.frames), motion);
  final st = ReplayStats();
  final seen = <int>{};
  var g = 0, z = 0;
  for (final f in log.frames) {
    if (motion != null) {
      for (; g < log.gyro.length && log.gyro[g].$1 + gyroDelayMs <= f.ms; g++) {
        final (t, x, y) = log.gyro[g];
        final (mx, my) = gyroMap?.call(x, y) ?? (x, y);
        motion.addSample(t + gyroDelayMs, mx, my);
      }
      for (; z < log.zooms.length && log.zooms[z].$1 <= f.ms; z++) {
        motion.zoom = log.zooms[z].$2;
      }
    }
    final out = await tracker.detect(Frame.file(
        timestampMs: f.ms, filePath: '', uprightSize: const Size(1, 1)));
    final ids = out.map((d) => d.trackingId).whereType<int>();
    final fresh = ids.where(seen.add).length;
    onFrame?.call(f.ms, fresh, out.length, ids.length);
    st
      ..frames += 1
      ..raw += out.length
      ..confirmed += ids.length
      ..ids += fresh
      ..newIdFrames += fresh > 0 ? 1 : 0;
  }
  if (log.frames.length > 1) {
    st.seconds = (log.frames.last.ms - log.frames.first.ms) / 1000;
  }
  return st;
}
