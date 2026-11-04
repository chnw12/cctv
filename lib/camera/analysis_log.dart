import 'dart:convert';
import 'dart:io';
import '../core/frame.dart';
import '../detection/detector.dart';

/// 분석 로그(재생 시험용): 실기기에서 ML Kit 원본 탐지(추적 전)와 자이로 원본을 그대로 적어 두고,
/// 테스트(`test/replay_log_test.dart`)에서 추적기를 여러 설정으로 다시 돌려 비교합니다
/// (자율주행의 로그 재생·재시뮬레이션: 한 번 녹화로 폰 없이 반복 튜닝).
/// 한 줄 = JSON 하나:
///   {"k":"meta", ...}                         카메라·렌즈 화각·시작 시각
///   {"k":"g","t":ms,"x":ωx,"y":ωy}            자이로 샘플(rad/s, 영점 보정 전)
///   {"k":"f","t":ms,"d":[[l,t,r,b,점수,"라벨"],…]} 처리한 프레임의 탐지(0..1, 똑바로 선 기준)
///   {"k":"z","t":ms,"z":배율}                  줌 변경
///   {"k":"img","t":ms,"f":"frames/….jpg"}      카메라 원본 화면(녹화할 때만, camera_recorder.dart)
class AnalysisLog {
  AnalysisLog(this.file);
  final File file;
  IOSink? _sink;
  int _lines = 0;

  /// 약 20MB 넘으면 그만 적음(14FPS·자이로 50Hz 기준 30분 이상)
  static const maxLines = 200000;

  void open(Map<String, Object?> meta) {
    file.parent.createSync(recursive: true);
    _sink = file.openWrite(mode: FileMode.append);
    _write({'k': 'meta', ...meta});
  }

  static double _r(double v) => (v * 10000).roundToDouble() / 10000;

  void gyro(int ms, double wx, double wy) =>
      _write({'k': 'g', 't': ms, 'x': _r(wx), 'y': _r(wy)});

  void frame(int ms, List<Detection> raw) => _write({
        'k': 'f',
        't': ms,
        'd': [
          for (final d in raw)
            [
              _r(d.box.left),
              _r(d.box.top),
              _r(d.box.right),
              _r(d.box.bottom),
              _r(d.confidence),
              d.label,
            ]
        ],
      });

  void zoom(int ms, double z) => _write({'k': 'z', 't': ms, 'z': _r(z)});

  void image(int ms, String file) => _write({'k': 'img', 't': ms, 'f': file});

  void _write(Map<String, Object?> m) {
    final s = _sink;
    if (s == null || _lines >= maxLines) return;
    s.writeln(jsonEncode(m));
    _lines++;
  }

  Future<void> close() async {
    final s = _sink;
    _sink = null;
    await s?.flush();
    await s?.close();
  }
}

/// 탐지기를 감싸 원본 결과를 넘김(추적기 안쪽에 끼움 → 추적 전 박스). 분석 로그·녹화가 받아 적음
class LoggingDetector implements Detector {
  LoggingDetector(this.inner, this.onRaw);
  final Detector inner;
  final void Function(int ms, List<Detection> raw) onRaw;

  @override
  Future<List<Detection>> detect(Frame frame) async {
    final r = await inner.detect(frame);
    onRaw(frame.timestampMs, r);
    return r;
  }

  @override
  Future<void> close() => inner.close();
}
