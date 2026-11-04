import 'dart:ui';
import 'package:facility_camera/core/frame.dart';
import 'package:facility_camera/detection/detector.dart';

// 비교용 기준선: 재구현 전 추적기(시간 기준 만료 + 탐욕 매칭 + lerp 스무딩) 그대로.
// 시나리오 테스트에서 새 추적기와 지표를 나란히 비교하는 데만 씁니다.

/// 아무 탐지기에나 씌우는 IoU 추적기. 프레임마다 독립 탐지된 박스를
/// 직전 박스와 겹침(IoU)으로 이어 붙여 같은 물체에 같은 trackingId를 줍니다.
/// ML Kit stream 모드의 내장 추적은 입력 FPS가 낮으면(에뮬레이터·USB 캠·저사양 폰)
/// 계속 리셋되어 아무것도 확정하지 못해서 직접 구현했습니다. YOLO로 바꿔도 그대로 사용.
class BaselineIouTracker implements Detector {
  BaselineIouTracker(
    this.inner, {
    this.minIou = 0.3,
    this.maxMissMs = 1000,
    this.smoothing = 0.5,
    this.minHits = 3,
  });

  final Detector inner;

  /// 이 이상 겹쳐야 같은 물체로 봄
  final double minIou;

  /// 이 시간 동안 안 보이면 추적 종료
  final int maxMissMs;

  /// 박스 떨림 완화(0 = 새 박스 그대로, 1 = 이전 박스 고정)
  final double smoothing;

  /// 이 횟수 이상 잡혀야(maxMissMs 안에서) ID 부여. 한두 프레임 깜빡이는 오탐에
  /// ID가 붙어 "새 물체"로 AI 자동 점검이 불필요하게 돌던 문제 방지(에뮬레이터에서 확인)
  final int minHits;

  final _tracks = <_Track>[];
  int _nextId = 1;

  @override
  Future<List<Detection>> detect(Frame frame) async {
    final dets = await inner.detect(frame);
    final now = frame.timestampMs;
    _tracks.removeWhere((t) => now - t.lastSeenMs > maxMissMs);

    // IoU 큰 쌍부터 탐욕적으로 매칭
    final pairs = <(double, int, int)>[];
    for (var d = 0; d < dets.length; d++) {
      for (var t = 0; t < _tracks.length; t++) {
        final v = iou(dets[d].box, _tracks[t].box);
        if (v >= minIou) pairs.add((v, d, t));
      }
    }
    pairs.sort((a, b) => b.$1.compareTo(a.$1));
    final detToTrack = <int, _Track>{};
    final usedTracks = <int>{};
    for (final (_, d, t) in pairs) {
      if (detToTrack.containsKey(d) || usedTracks.contains(t)) continue;
      detToTrack[d] = _tracks[t];
      usedTracks.add(t);
    }

    final out = <Detection>[];
    for (var d = 0; d < dets.length; d++) {
      final det = dets[d];
      var track = detToTrack[d];
      if (track == null) {
        track = _Track(det.box, now);
        _tracks.add(track);
      } else {
        track
          ..box = Rect.lerp(det.box, track.box, smoothing)!
          ..lastSeenMs = now
          ..hits += 1;
      }
      if (track.id == null && track.hits >= minHits) track.id = _nextId++;
      out.add(Detection(
        trackingId: track.id,
        box: track.box,
        label: det.label,
        confidence: det.confidence,
      ));
    }
    return out;
  }

  static double iou(Rect a, Rect b) {
    final i = a.intersect(b);
    if (i.width <= 0 || i.height <= 0) return 0;
    final inter = i.width * i.height;
    return inter / (a.width * a.height + b.width * b.height - inter);
  }

  @override
  Future<void> close() => inner.close();
}

class _Track {
  _Track(this.box, this.lastSeenMs);
  int? id; // minHits 채우기 전에는 null
  Rect box;
  int lastSeenMs;
  int hits = 1;
}
