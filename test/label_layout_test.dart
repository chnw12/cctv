import 'dart:ui';
import 'package:facility_camera/ui/box_painter.dart';
import 'package:flutter_test/flutter_test.dart';

/// 위험 이름표 자리: 서로 겹치지 않고 화면 안에(실제 폰 사진에서 "천장 오염"·"벽면 균열" 글자가 가려졌던 문제)
void main() {
  const label = Size(100, 22);

  void noOverlap(List<Rect> spots, Size view) {
    for (var a = 0; a < spots.length; a++) {
      expect(spots[a].top >= 0 && spots[a].bottom <= view.height, isTrue,
          reason: '이름표 $a가 화면 위아래 밖');
      expect(spots[a].left >= 0 && spots[a].right <= view.width, isTrue,
          reason: '이름표 $a가 화면 옆 밖');
      for (var b = a + 1; b < spots.length; b++) {
        expect(spots[a].overlaps(spots[b]), isFalse, reason: '이름표 $a와 $b가 겹침');
      }
    }
  }

  test('실제 폰 사진 재현: 천장 오염·벽면 균열·배선 노출 이름표가 서로 안 겹침', () {
    const view = Size(507, 900);
    final spots = HazardBoxPainter.placeLabels(const [
      Rect.fromLTRB(0, 0, 507, 205), // 천장 오염(천장 전체)
      Rect.fromLTRB(135, 190, 215, 320), // 벽면 균열(작은 박스)
      Rect.fromLTRB(75, 215, 230, 375), // 배선 노출(균열과 겹침)
    ], const [
      label,
      label,
      label
    ], view);
    noOverlap(spots, view);
    expect(spots[0].top, 207); // 가장 심각한 첫 위험은 기본 자리(박스 바로 아래)
  });

  test('기본은 박스 아래, 아래가 모자라면 위, 오른쪽 끝 박스는 화면 안으로 밀어 넣음', () {
    const view = Size(400, 800);
    final one = HazardBoxPainter.placeLabels(
        const [Rect.fromLTWH(50, 100, 120, 80)], const [label], view);
    expect(one.single.top, 182);
    expect(one.single.left, 50);

    final bottom = HazardBoxPainter.placeLabels(
        const [Rect.fromLTWH(50, 700, 120, 95)], const [label], view);
    expect(bottom.single.bottom, lessThanOrEqualTo(700)); // 위로

    final right = HazardBoxPainter.placeLabels(
        const [Rect.fromLTWH(360, 100, 40, 40)], const [label], view);
    expect(right.single.right, lessThanOrEqualTo(400));
  });

  test('같은 자리에 박스 여러 개가 겹쳐도 이름표는 차례로 비켜 남', () {
    const view = Size(400, 800);
    final spots = HazardBoxPainter.placeLabels(
        List.filled(5, const Rect.fromLTWH(100, 300, 150, 100)),
        List.filled(5, label),
        view);
    noOverlap(spots, view);
  });
}
