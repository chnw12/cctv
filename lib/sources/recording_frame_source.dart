import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import '../core/frame.dart';
import 'frame_source.dart';

/// 녹화 하나(폴더, camera_recorder.dart)의 요약 — 목록·고르기 화면용
class Recording {
  Recording(this.dir, {required this.frames, required this.seconds});
  final Directory dir;
  final int frames;
  final double seconds;

  String get name => dir.path.split(RegExp(r'[\\/]')).last;

  /// 폰의 녹화 폴더(adb로 꺼낼 수 있는 앱 외부 저장소). 없는 환경이면 null
  static Future<Directory?> root() async {
    try {
      final ext = await getExternalStorageDirectory();
      return ext == null ? null : Directory('${ext.path}/recordings');
    } catch (_) {
      return null;
    }
  }

  /// 최근 것부터. 요약(summary.json)이 없으면(녹화 중 꺼짐 등) 로그의 화면 줄 수로 셈
  static Future<List<Recording>> list(Directory root) async {
    if (!await root.exists()) return const [];
    final out = <Recording>[];
    await for (final d in root.list()) {
      if (d is! Directory) continue;
      final log = File('${d.path}/log.jsonl');
      if (!await log.exists()) continue;
      var frames = 0;
      var seconds = 0.0;
      try {
        final s =
            jsonDecode(await File('${d.path}/summary.json').readAsString())
                as Map<String, dynamic>;
        frames = (s['frames'] as num).toInt();
        seconds = (s['seconds'] as num).toDouble();
      } catch (_) {
        int? first, last;
        for (final line in await log.readAsLines()) {
          if (!line.contains('"k":"img"')) continue;
          final t = (jsonDecode(line)['t'] as num).toInt();
          first ??= t;
          last = t;
          frames++;
        }
        if (first != null) seconds = (last! - first) / 1000;
      }
      if (frames > 0) out.add(Recording(d, frames: frames, seconds: seconds));
    }
    out.sort((a, b) => b.name.compareTo(a.name));
    return out;
  }
}

/// 녹화를 진짜 카메라처럼 흘림: 원래 시간 간격대로 JPEG를 NV21로 풀어(안드로이드 쪽) 카메라와 같은
/// [Frame]으로 내보내고, 그 사이 자이로·줌도 같은 시각에 [gyro]·[zooms]로 내보냄.
/// 그래서 탐지·추적·손 인식·AI 점검이 실제 카메라와 똑같은 길로 돎(새 기능을 같은 장면으로 반복 시험).
/// 시각은 "지금" 기준으로 옮겨 내보냄(앱의 다른 시간 계산과 섞여도 맞게). 처리하느라 늦으면
/// 실제 카메라처럼 지난 화면은 건너뜀. 끝나면 처음부터 다시(loop)
class RecordingFrameSource implements FrameSource {
  RecordingFrameSource(this.dir, {this.loop = true});
  final Directory dir;
  final bool loop;

  static const _ch = MethodChannel('facility_camera/recorder');

  final _out = StreamController<Frame>.broadcast();
  // 자이로는 같은 시각 화면보다 먼저 반영돼야 해서 바로(sync) 전달
  final _gyro = StreamController<(int, double, double)>.broadcast(sync: true);
  final _zooms = StreamController<double>.broadcast(sync: true);
  final _current = ValueNotifier<String?>(null);
  final _aspect = ValueNotifier<double>(9 / 16);

  final _images = <(int, String)>[];
  final _gyros = <(int, double, double)>[];
  final _zoomAt = <(int, double)>[];
  int _rotation = 0;
  bool _running = false;

  /// 녹화 당시 렌즈 화각(가로, 세로 rad)·시작 줌. 자이로 환산에 씀
  Size? lensFov;
  double zoom = 1;

  /// 자이로 샘플(시각 ms, ωx, ωy) — 파이프라인이 자이로 센서 대신 받아 씀
  Stream<(int, double, double)> get gyro => _gyro.stream;
  Stream<double> get zooms => _zooms.stream;

  @override
  String get name => '녹화 재생';
  @override
  ValueListenable<double> get aspectRatio => _aspect;
  @override
  Stream<Frame> get frames => _out.stream;
  @override
  CameraControls? get controls => null;

  @override
  Future<void> start() async {
    final log = File('${dir.path}/log.jsonl');
    if (!await log.exists()) throw StateError('녹화 기록이 없습니다: ${dir.path}');
    double n(Object? v) => (v as num).toDouble();
    for (final line in await log.readAsLines()) {
      if (line.trim().isEmpty) continue;
      final m = jsonDecode(line) as Map<String, dynamic>;
      switch (m['k']) {
        case 'meta':
          _rotation = (m['rotation'] as num?)?.toInt() ?? 0;
          zoom = n(m['zoom'] ?? 1);
          final fov = m['lensFov'];
          if (fov is List) lensFov = Size(n(fov[0]), n(fov[1]));
          final w = n(m['rawW'] ?? 9), h = n(m['rawH'] ?? 16);
          _aspect.value = _rotation == 90 || _rotation == 270 ? h / w : w / h;
        case 'img':
          _images.add(((m['t'] as num).toInt(), m['f'] as String));
        case 'g':
          _gyros.add(((m['t'] as num).toInt(), n(m['x']), n(m['y'])));
        case 'z':
          _zoomAt.add(((m['t'] as num).toInt(), n(m['z'])));
      }
    }
    if (_images.isEmpty) throw StateError('녹화에 화면이 없습니다: ${dir.path}');
    _running = true;
    unawaited(_play());
  }

  Future<void> _play() async {
    do {
      final t0 = _images.first.$1;
      final base = DateTime.now().millisecondsSinceEpoch;
      var g = 0, z = 0;
      for (var i = 0; i < _images.length && _running; i++) {
        final (t, file) = _images[i];
        final wait = base + (t - t0) - DateTime.now().millisecondsSinceEpoch;
        if (wait > 0) {
          await Future<void>.delayed(Duration(milliseconds: wait));
        } else if (i + 1 < _images.length &&
            base + (_images[i + 1].$1 - t0) <=
                DateTime.now().millisecondsSinceEpoch) {
          continue; // 다음 화면 시각도 지남 → 이 화면은 건너뜀(자이로는 다음 화면 때 함께)
        }
        if (!_running) return;
        for (; g < _gyros.length && _gyros[g].$1 <= t; g++) {
          final (gt, x, y) = _gyros[g];
          _gyro.add((base + gt - t0, x, y));
        }
        for (; z < _zoomAt.length && _zoomAt[z].$1 <= t; z++) {
          _zooms.add(_zoomAt[z].$2);
        }
        final path = '${dir.path}/$file';
        final Map<String, Object?>? img;
        try {
          img = await _ch
              .invokeMapMethod<String, Object?>('loadNv21', {'path': path});
        } catch (e) {
          debugPrint('녹화 화면 읽기 실패($file): $e');
          continue;
        }
        if (!_running || img == null) return;
        final w = (img['w'] as num).toDouble(),
            h = (img['h'] as num).toDouble();
        final turned = _rotation == 90 || _rotation == 270;
        _current.value = path;
        _out.add(Frame.raw(
          timestampMs: base + t - t0,
          format: FrameFormat.nv21,
          bytes: img['bytes'] as Uint8List,
          rawSize: Size(w, h),
          rotationDegrees: _rotation,
          bytesPerRow: w.toInt(),
          uprightSize: turned ? Size(h, w) : Size(w, h),
        ));
      }
    } while (loop && _running);
  }

  @override
  Future<void> stop() async => _running = false;

  @override
  Future<void> dispose() async {
    await stop();
    await _out.close();
    await _gyro.close();
    await _zooms.close();
    _current.dispose();
    _aspect.dispose();
  }

  /// AI 점검 사진: 지금 화면을 똑바로 세우고 긴 변 1024px로(카메라 촬영과 같은 크기)
  @override
  Future<Uint8List> snapshotJpeg() async {
    final p = _current.value;
    if (p == null) throw StateError('녹화 화면 준비 안 됨');
    final jpeg = await _ch.invokeMethod<Uint8List>('uprightJpeg',
        {'path': p, 'rotation': _rotation, 'maxSide': 1024, 'quality': 80});
    if (jpeg == null) throw StateError('녹화 화면을 사진으로 바꾸지 못함');
    return jpeg;
  }

  @override
  Widget buildPreview(BuildContext context) => ValueListenableBuilder<String?>(
        valueListenable: _current,
        builder: (_, p, __) => p == null
            ? const SizedBox.shrink()
            : RotatedBox(
                quarterTurns: _rotation ~/ 90,
                child: Image.file(File(p),
                    fit: BoxFit.fill, gaplessPlayback: true),
              ),
      );
}
