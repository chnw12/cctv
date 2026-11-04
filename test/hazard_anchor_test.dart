import 'dart:ui';
import 'package:facility_camera/analysis/hazard.dart';
import 'package:facility_camera/camera/hazard_anchor.dart';
import 'package:facility_camera/core/frame.dart';
import 'package:flutter_test/flutter_test.dart';

Hazard _h(Rect b) => Hazard(
    type: 't', description: '', severity: Severity.high, action: '', box: b);
Detection _t(int? id, Rect b) =>
    Detection(trackingId: id, box: b, label: '', confidence: 0);

void main() {
  test('위험 박스를 가장 많이 품은 트랙에 붙임, 겹침 부족·ID 없는 트랙은 무시', () {
    final hazards = [
      _h(const Rect.fromLTWH(0.32, 0.32, 0.1, 0.1)), // 트랙1 안
      _h(const Rect.fromLTWH(0.8, 0.8, 0.1, 0.1)), // 아무 트랙과도 안 겹침
      _h(const Rect.fromLTWH(0.55, 0.3, 0.1, 0.1)), // 트랙2와 30%만 겹침 → 안 붙임
    ];
    final tracks = [
      _t(1, const Rect.fromLTWH(0.3, 0.3, 0.2, 0.2)),
      _t(2, const Rect.fromLTWH(0.62, 0.3, 0.2, 0.2)),
      _t(null, const Rect.fromLTWH(0.78, 0.78, 0.2, 0.2)), // 확정 전 트랙
    ];
    final a = HazardAnchor.match(hazards, tracks);
    expect(a.keys, [0]);
    expect(a[0]!.trackId, 1);
  });

  test('트랙이 옮겨지고 2배 커지면 위험 박스도 같은 상대 위치·비율로', () {
    const h = Rect.fromLTWH(0.35, 0.35, 0.05, 0.05);
    const t0 = Rect.fromLTWH(0.3, 0.3, 0.2, 0.2);
    const t1 = Rect.fromLTWH(0.1, 0.2, 0.4, 0.4);
    final r = HazardAnchor.follow(h, t0, t1);
    expect(r.left, closeTo(0.2, 1e-9)); // 트랙 안 25% 지점
    expect(r.top, closeTo(0.3, 1e-9));
    expect(r.width, closeTo(0.1, 1e-9));
  });

  test('지금 안 보이는 트랙에 붙은 위험은 빠짐(→ 자이로로 대신 옮김)', () {
    final hazards = [_h(const Rect.fromLTWH(0.32, 0.32, 0.1, 0.1))];
    final anchors = {
      0: const HazardAnchor(7, Rect.fromLTWH(0.3, 0.3, 0.2, 0.2))
    };
    expect(HazardAnchor.place(hazards, anchors, []), isEmpty);
    final moved = HazardAnchor.place(
        hazards, anchors, [_t(7, const Rect.fromLTWH(0.4, 0.3, 0.2, 0.2))]);
    expect(moved[0]!.left, closeTo(0.42, 1e-9));
  });
}
