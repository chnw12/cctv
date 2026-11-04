import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';
import '../core/frame.dart';

/// 손 하나의 관절점 21개(MediaPipe 순서: 0 손목, 4 엄지 끝, 8 검지 끝 …).
/// 좌표는 똑바로 선 프레임 기준 0..1 → 탐지 박스·위험 박스와 같은 좌표계
class HandLandmarks {
  const HandLandmarks(this.points);
  final List<Offset> points;

  static const wrist = 0, indexTip = 8;

  Offset get tip => points[indexTip];

  /// 손목 → 검지 끝 거리. 손이 둘이면 손가락을 뻗어 가리키는 손(더 긴 쪽)을 씀
  double get pointing => (points[indexTip] - points[wrist]).distance;

  /// 채널 응답 [x0, y0, z0, x1, …](63개)
  factory HandLandmarks.fromFlat(List<num> v) => HandLandmarks([
        for (var i = 0; i + 2 < v.length; i += 3)
          Offset(v[i].toDouble(), v[i + 1].toDouble())
      ]);
}

/// 한 프레임의 손 인식 결과(프레임 시각 기준이라 머무르기 시간을 그대로 잴 수 있음)
class HandFrame {
  const HandFrame(this.ms, this.hands);
  final int ms;
  final List<HandLandmarks> hands;

  /// 가리키는 손(손가락을 가장 길게 뻗은 손), 없으면 null
  HandLandmarks? get pointer => hands.isEmpty
      ? null
      : hands.reduce((a, b) => b.pointing > a.pointing ? b : a);
}

abstract class HandTracker {
  Future<List<HandLandmarks>> detect(Frame f);
  Future<void> close();
}

/// MediaPipe 손 관절점(Kotlin `HandChannel`). 카메라 프레임(NV21, 센서 방향)을 똑바로 세우고
/// 1/3로 줄여(720x1280 → 240x426) RGBA로 넘김: 손바닥 탐지 입력이 192px이라 이 정도면 충분하고 전송이 가벼움
class MediaPipeHandTracker implements HandTracker {
  static const _ch = MethodChannel('facility_camera/hands');
  static const step = 3;

  /// GPU로 돌았는지(Kotlin이 GPU 먼저, 안 되면 CPU). 처음 알게 되면 PERF 로그에 한 번 남김
  bool? gpu;

  @override
  Future<List<HandLandmarks>> detect(Frame f) async {
    final img = uprightRgba(f, step: step);
    if (img == null) return const [];
    final res = await _ch.invokeMapMethod<String, Object?>('detect', {
      'rgba': img.rgba,
      'w': img.width,
      'h': img.height,
      'ts': f.timestampMs,
    });
    final g = res?['gpu'] == true;
    if (gpu != g) debugPrint('PERF hand delegate=${g ? 'gpu' : 'cpu'}');
    gpu = g;
    return [
      for (final h in (res?['hands'] as List?) ?? const <Object?>[])
        HandLandmarks.fromFlat((h as List).cast<num>())
    ];
  }

  @override
  Future<void> close() => _ch.invokeMethod<void>('close');
}

/// NV21(센서 방향) → 똑바로 선 RGBA, step 칸마다 한 점(가장 가까운 점). NV21이 아니면 null.
/// 회전: 똑바로 선 (ux, uy)가 센서의 어느 점인지 —
/// 90°: (uy, H−1−ux), 180°: (W−1−ux, H−1−uy), 270°: (W−1−uy, ux)
({Uint8List rgba, int width, int height})? uprightRgba(Frame f,
    {int step = 3}) {
  final bytes = f.bytes, raw = f.rawSize;
  if (f.format != FrameFormat.nv21 || bytes == null || raw == null) return null;
  final sw = raw.width.toInt(), sh = raw.height.toInt();
  final stride = f.bytesPerRow > 0 ? f.bytesPerRow : sw;
  if (sw <= 0 || sh <= 0 || bytes.length < stride * sh) return null;
  final rot = f.rotationDegrees % 360;
  final turned = rot == 90 || rot == 270;
  final uw = (turned ? sh : sw) ~/ step, uh = (turned ? sw : sh) ~/ step;
  if (uw <= 0 || uh <= 0) return null;
  // 색(VU)이 잘려 들어오면 흑백으로라도
  final uvBase = stride * sh;
  final hasUv = bytes.length >= uvBase + stride * ((sh + 1) ~/ 2);
  final out = Uint8List(uw * uh * 4);
  var o = 0;
  for (var oy = 0; oy < uh; oy++) {
    final uy = oy * step + step ~/ 2;
    for (var ox = 0; ox < uw; ox++) {
      final ux = ox * step + step ~/ 2;
      final int sx, sy;
      switch (rot) {
        case 90:
          sx = uy;
          sy = sh - 1 - ux;
        case 180:
          sx = sw - 1 - ux;
          sy = sh - 1 - uy;
        case 270:
          sx = sw - 1 - uy;
          sy = ux;
        default:
          sx = ux;
          sy = uy;
      }
      final y = bytes[sy * stride + sx];
      var r = y, g = y, b = y;
      if (hasUv) {
        final i = uvBase + (sy >> 1) * stride + (sx & ~1);
        final v = bytes[i] - 128, u = bytes[i + 1] - 128; // NV21 = V, U 순서
        r = y + ((359 * v) >> 8);
        g = y - ((88 * u + 183 * v) >> 8);
        b = y + ((454 * u) >> 8);
      }
      out[o++] = r.clamp(0, 255);
      out[o++] = g.clamp(0, 255);
      out[o++] = b.clamp(0, 255);
      out[o++] = 255;
    }
  }
  return (rgba: out, width: uw, height: uh);
}
