import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../core/frame.dart';
import 'analysis_log.dart';

/// 시험용 녹화: 카메라 원본 화면 + 자이로 + 줌 + 원본 탐지를 그대로 남겨, 나중에 같은 장면을 앱에 다시 흘려
/// 새 기능(탐지기·추적기·손 인식·AI)을 몇 번이고 시험함(자율주행의 주행 기록 재생과 같은 방식).
/// 폴더 하나 = 녹화 하나:
///   <폴더>/log.jsonl         분석 로그 형식(analysis_log.dart) + {"k":"img"} 줄. PC 재생 테스트에도 그대로 씀
///   <폴더>/frames/<ms>.jpg   카메라 원본(센서 방향 그대로, 회전은 meta의 rotation)
/// 화면 저장(JPEG 변환)은 안드로이드 쪽 스레드에서. 밀리면(2장 넘게 대기) 그 장은 건너뛰고 [dropped]로 셈.
/// 시연 영상(앱 화면 그대로)은 이게 아니라 폰의 "화면 녹화" 기능으로 찍음
class CameraRecorder {
  CameraRecorder(this.dir, {this.quality = 80});

  final Directory dir;
  final int quality;

  static const _ch = MethodChannel('facility_camera/recorder');

  /// 자동으로 멈추는 길이(약 60MB/분이라 10분이면 600MB 안팎)
  static const maxSeconds = 600;
  static const _maxPending = 2;

  late final AnalysisLog _log = AnalysisLog(File('${dir.path}/log.jsonl'));
  bool _metaWritten = false;
  Map<String, Object?> _meta = const {};
  int _pending = 0;
  int? _firstMs, _lastMs;

  int frames = 0, dropped = 0, bytes = 0;
  bool get open => _open;
  bool _open = false;

  /// 멈추는 중(새 화면은 안 받고 남은 저장만 마무리)
  bool get stopping => _stopping;
  bool _stopping = false;

  /// 녹화 길이(초)
  double get seconds =>
      _firstMs == null || _lastMs == null ? 0 : (_lastMs! - _firstMs!) / 1000;

  /// meta는 첫 프레임에서 회전·크기를 더해 적음(카메라마다 다름)
  void start(Map<String, Object?> meta) {
    dir.createSync(recursive: true);
    _meta = meta;
    _open = true;
  }

  void gyro(int ms, double wx, double wy) {
    if (_metaWritten) _log.gyro(ms, wx, wy);
  }

  void zoom(int ms, double z) {
    if (_metaWritten) _log.zoom(ms, z);
  }

  void detections(int ms, List<Detection> raw) {
    if (_metaWritten) _log.frame(ms, raw);
  }

  /// 카메라 원본(NV21)만 저장. 다른 입력(테스트 사진·재생 중인 녹화)은 무시
  void addFrame(Frame f) {
    final bytes = f.bytes, raw = f.rawSize;
    if (!_open ||
        _stopping ||
        f.format != FrameFormat.nv21 ||
        bytes == null ||
        raw == null) {
      return;
    }
    if (!_metaWritten) {
      _log.open({
        ..._meta,
        'rotation': f.rotationDegrees,
        'rawW': raw.width.toInt(),
        'rawH': raw.height.toInt(),
      });
      _metaWritten = true;
      _firstMs = f.timestampMs;
    }
    if (_pending >= _maxPending) {
      dropped++;
      return;
    }
    _pending++;
    final name = 'frames/${f.timestampMs}.jpg';
    _ch.invokeMethod<int>('saveJpeg', {
      'nv21': bytes,
      'w': raw.width.toInt(),
      'h': raw.height.toInt(),
      'stride': f.bytesPerRow,
      'path': '${dir.path}/$name',
      'quality': quality,
    }).then((size) {
      if (!_open) return;
      _log.image(f.timestampMs, name);
      frames++;
      this.bytes += size ?? 0;
      _lastMs = f.timestampMs;
    }, onError: (Object e) {
      dropped++;
      debugPrint('녹화 저장 실패: $e');
    }).whenComplete(() => _pending--);
  }

  /// 멈추고 요약을 적음(새 화면은 바로 끊고, 남은 저장이 끝날 때까지 잠깐 기다림)
  Future<void> stop() async {
    _stopping = true;
    for (var i = 0; i < 50 && _pending > 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    _open = false;
    await _log.close();
    await File('${dir.path}/summary.json').writeAsString(jsonEncode({
      'frames': frames,
      'dropped': dropped,
      'seconds': seconds,
      'bytes': bytes,
    }));
  }
}
