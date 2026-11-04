import 'dart:ui';
import '../analysis/hazard.dart';
import '../core/frame.dart';

/// 위험 표시를 "추적 중인 물체"에 붙이기.
/// AI 사진을 찍던 순간 위험 박스와 가장 많이 겹친 트랙(ID)을 기억해 두고, 이후 그 트랙 박스가
/// 움직이거나 커지면 위험 박스도 같은 비율로 따라감. 자이로가 없거나(USB 카메라) 물체 자체가
/// 움직여도 표시가 붙어 있음. 겹치는 트랙이 없으면 자이로 이동량으로 대신 옮김.
class HazardAnchor {
  const HazardAnchor(this.trackId, this.trackBox);
  final int trackId;

  /// 사진 찍던 순간의 트랙 박스(0..1)
  final Rect trackBox;

  /// 위험 박스가 이 비율 이상 트랙 안에 들어 있어야 그 물체의 위험으로 봄
  static const minContained = 0.5;

  /// 위험 i → 붙일 트랙. 위험 박스 기준으로 트랙과 겹친 비율이 가장 큰 것
  static Map<int, HazardAnchor> match(
      List<Hazard> hazards, List<Detection> tracks) {
    final out = <int, HazardAnchor>{};
    for (var i = 0; i < hazards.length; i++) {
      final h = hazards[i].box;
      if (h == null || h.isEmpty) continue;
      HazardAnchor? best;
      var bestScore = minContained;
      for (final t in tracks) {
        final id = t.trackingId;
        if (id == null) continue;
        final inter = h.intersect(t.box);
        if (inter.width <= 0 || inter.height <= 0) continue;
        final score = inter.width * inter.height / (h.width * h.height);
        if (score >= bestScore) {
          bestScore = score;
          best = HazardAnchor(id, t.box);
        }
      }
      if (best != null) out[i] = best;
    }
    return out;
  }

  /// 트랙이 track0 → track1 로 움직였을 때 그 안의 위험 박스 위치(상대 위치·크기 비율 유지)
  static Rect follow(Rect hazard, Rect track0, Rect track1) {
    double x(double v) =>
        track1.left + (v - track0.left) / track0.width * track1.width;
    double y(double v) =>
        track1.top + (v - track0.top) / track0.height * track1.height;
    return Rect.fromLTRB(
        x(hazard.left), y(hazard.top), x(hazard.right), y(hazard.bottom));
  }

  /// 지금 프레임의 트랙들로 붙어 있는 위험들의 새 위치(트랙이 안 보이면 빠짐)
  static Map<int, Rect> place(List<Hazard> hazards,
      Map<int, HazardAnchor> anchors, List<Detection> tracks) {
    final byId = {
      for (final t in tracks)
        if (t.trackingId != null) t.trackingId!: t.box
    };
    final out = <int, Rect>{};
    anchors.forEach((i, a) {
      final now = byId[a.trackId];
      final h = hazards[i].box;
      if (now != null && h != null) out[i] = follow(h, a.trackBox, now);
    });
    return out;
  }
}
