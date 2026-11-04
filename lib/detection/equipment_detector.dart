import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../analysis/hazard.dart';
import '../core/frame.dart';
import '../hands/hand_tracker.dart' show uprightRgba;
import 'detector.dart';

/// 설비 전용 탐지기(시험): 밸브·배관·분전반 등 [Equipment.labels] 10종을 찾는 YOLO 계열 ONNX 모델.
/// 지금 모델은 YOLOE에 설비 이름을 넣어 고정한 것(학습 없이, AGPL → 시연·내부 평가용, 배포 금지).
/// 공개 기계실 사진에서 점수가 0.1~0.6으로 낮고 배관·밸브를 자주 놓침 → 기준 점수를 0.15로 낮춤.
/// 만드는 법: tool/equipment_model.py export
/// 나중에 우리 데이터로 학습한 Apache 모델로 같은 자리(assets/equipment.onnx)를 바꾸면 됨.
/// 추론은 안드로이드 쪽(EquipmentChannel.kt, ONNX Runtime)에서, 여기서는 똑바로 세우고 줄인 RGBA만 넘김.
class EquipmentDetector implements Detector {
  EquipmentDetector({this.inputSize = 480, this.minConfidence = 0.15});

  /// 모델 입력의 긴 변(px). 프레임을 이 정도로 줄여 보냄(넘기는 양·변환 시간 절약)
  final int inputSize;
  final double minConfidence;

  static const _ch = MethodChannel('facility_camera/equipment');
  static final _names = Equipment.labels.keys.toList();

  /// 마지막 추론 정보(PERF 줄): 실행 장치·추론 시간
  String? delegate;
  int lastMs = 0;

  int _logMs = 0;
  final _loggedFiles = <String>{};

  @override
  Future<List<Detection>> detect(Frame f) async {
    // 테스트 이미지(사진 파일)는 안드로이드 쪽에서 읽어 줄임. 사진마다 처음 한 번 결과를 로그로(PC 결과와 비교용)
    if (f.format == FrameFormat.file) {
      final out = await _run({'path': f.filePath, 'size': inputSize});
      if (_loggedFiles.add(f.filePath!)) {
        debugPrint('PERF equipment file=${f.filePath!.split('/').last} '
            'ms=$lastMs ${out.map((d) => '${d.label}:${d.confidence.toStringAsFixed(2)}'
                '@${[
                  d.box.left,
                  d.box.top,
                  d.box.right,
                  d.box.bottom
                ].map((v) => v.toStringAsFixed(2)).join(',')}').join(' ')}');
      }
      return out;
    }
    final raw = f.rawSize;
    if (raw == null) return const [];
    final longSide = raw.longestSide.toInt();
    // 올림: 720p(1280)면 3칸마다 → 426px(모델이 480으로 살짝 키움). 내림(2칸, 640px)은 화면 스레드 변환이 2배
    final step = ((longSide + inputSize - 1) ~/ inputSize).clamp(1, 8);
    final img = uprightRgba(f, step: step);
    if (img == null) return const [];
    final out = await _run({'rgba': img.rgba, 'w': img.width, 'h': img.height});
    // 2초마다 추론 시간(안드로이드 쪽, 변환·전달 제외)
    if (f.timestampMs - _logMs >= 2000) {
      _logMs = f.timestampMs;
      debugPrint(
          'PERF equipment model=${lastMs}ms in=${img.width}x${img.height} '
          'boxes=${out.length}');
    }
    return out;
  }

  Future<List<Detection>> _run(Map<String, Object?> args) async {
    final res = await _ch.invokeMapMethod<String, Object?>(
        'detect', {...args, 'minConf': minConfidence});
    final d = res?['delegate'] as String?;
    if (d != delegate) debugPrint('PERF equipment delegate=$d');
    delegate = d;
    lastMs = (res?['ms'] as num?)?.toInt() ?? 0;
    return parse((res?['boxes'] as List?)?.cast<num>() ?? const []);
  }

  /// 채널 결과: 박스마다 [l, t, r, b, 점수, 클래스번호] (똑바로 선 화면 기준 0..1)
  @visibleForTesting
  static List<Detection> parse(List<num> flat) => [
        for (var i = 0; i + 5 < flat.length; i += 6)
          Detection(
            trackingId: null,
            box: Rect.fromLTRB(
              flat[i].toDouble().clamp(0.0, 1.0),
              flat[i + 1].toDouble().clamp(0.0, 1.0),
              flat[i + 2].toDouble().clamp(0.0, 1.0),
              flat[i + 3].toDouble().clamp(0.0, 1.0),
            ),
            label:
                Equipment.labels[_names.elementAtOrNull(flat[i + 5].toInt())] ??
                    '',
            confidence: flat[i + 4].toDouble(),
          )
      ];

  @override
  Future<void> close() => _ch.invokeMethod<void>('close');
}
