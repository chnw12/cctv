import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../analysis/hazard.dart';
import '../core/frame.dart';
import 'hazard_panel.dart';

class DetectionPainter extends CustomPainter {
  DetectionPainter(this.detections);
  final List<Detection> detections;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = Colors.greenAccent;

    for (final d in detections) {
      final r = Rect.fromLTRB(d.box.left * size.width, d.box.top * size.height,
          d.box.right * size.width, d.box.bottom * size.height);
      canvas.drawRect(r, stroke);

      final text = [
        if (d.trackingId != null) '#${d.trackingId}',
        if (d.label.isNotEmpty) '${d.label} ${(d.confidence * 100).round()}%',
      ].join(' ');
      final tp = TextPainter(
        text: TextSpan(
            text: text,
            style: const TextStyle(
                color: Colors.black,
                fontSize: 12,
                fontWeight: FontWeight.bold)),
        textDirection: TextDirection.ltr,
      )..layout();
      final bg = Rect.fromLTWH(
          r.left, r.top - tp.height - 2, tp.width + 8, tp.height + 2);
      canvas.drawRect(bg, Paint()..color = Colors.greenAccent);
      tp.paint(canvas, Offset(bg.left + 4, bg.top + 1));
    }
  }

  @override
  bool shouldRepaint(DetectionPainter old) => old.detections != detections;
}

/// 선택한 위험 박스 옆 [무시] [완료] 버튼 자리(화면 px). 화면 탭 버튼과 손가락 누르기 판정이 같이 씀.
/// 장갑 손가락으로 누르기 쉽게 높이 56, 박스가 화면 아래쪽이면 위에(아래는 결과 패널·버튼이 가림),
/// 위쪽이면 아래에 붙이고 화면 안으로 맞춤
class HazardActionLayout {
  const HazardActionLayout(this.ignore, this.done);
  final Rect ignore, done;

  static const height = 56.0, gap = 10.0, between = 8.0, maxWidth = 300.0;

  factory HazardActionLayout.of(Rect hazard, Size view) {
    final w = (view.width - 16).clamp(0.0, maxWidth).toDouble();
    final above = hazard.center.dy > view.height / 2;
    final top = (above ? hazard.top - height - gap : hazard.bottom + gap)
        .clamp(8.0, math.max(8.0, view.height - height - 8))
        .toDouble();
    final left = (hazard.center.dx - w / 2)
        .clamp(8.0, math.max(8.0, view.width - w - 8))
        .toDouble();
    final half = (w - between) / 2;
    return HazardActionLayout(Rect.fromLTWH(left, top, half, height),
        Rect.fromLTWH(left + half + between, top, half, height));
  }
}

/// Gemini가 짚은 위험요소 위치. 스냅샷과 미리보기 비율이 다르면
/// 미리보기를 스냅샷의 가운데 crop으로 보고(cover) 맞춥니다.
/// shift: 찍은 뒤 카메라가 움직인 만큼(화면 비율) 옮겨 위험 표시를 실제 위치에 붙여 둠.
/// 처리 상태: 완료는 초록 "✓", 무시는 안 그림(기록 화면은 [showIgnored]로 회색 표시)
class HazardBoxPainter extends CustomPainter {
  HazardBoxPainter(this.report,
      {this.shift = Offset.zero,
      this.anchored = const {},
      this.selected,
      this.revision = 0,
      this.showIgnored = false});
  final HazardReport report;
  final Offset shift;

  /// 추적 중인 물체에 붙어 따라가는 위험의 현재 박스(위험 번호 → 박스). 이 위험들은 shift 안 씀
  final Map<int, Rect> anchored;

  /// 눌러서 무시·완료 버튼을 띄운 위험(굵은 흰 테두리)
  final int? selected;

  /// 처리 상태가 바뀔 때마다 올라가는 번호(같은 결과 객체라도 다시 그리게)
  final int revision;
  final bool showIgnored;

  static const resolvedColor = Colors.greenAccent;

  /// 위험 번호 → 화면 사각형(위치 없는 위험·무시한 위험은 빠짐). 그리기와 탭 판정이 같이 씀
  static Map<int, Rect> viewRects(HazardReport report, Size view,
      {Offset shift = Offset.zero,
      Map<int, Rect> anchored = const {},
      bool includeIgnored = false}) {
    final out = <int, Rect>{};
    for (var i = 0; i < report.hazards.length; i++) {
      final h = report.hazards[i];
      final b = anchored[i] ?? h.box;
      if (b == null || (!includeIgnored && h.status == HazardStatus.ignored)) {
        continue;
      }
      out[i] = toView(b, report.imageSize, view,
          anchored.containsKey(i) ? Offset.zero : shift);
    }
    return out;
  }

  /// 화면 p를 눌렀을 때 고를 위험(아직 처리 안 된 것만). 장갑 손가락을 생각해 [slop]만큼 넓게 보고,
  /// 여러 개가 겹치면 가장 작은 박스(안쪽 물체)를 고름
  static int? hazardAt(HazardReport report, Size view, Offset p,
      {Offset shift = Offset.zero,
      Map<int, Rect> anchored = const {},
      double slop = 16}) {
    int? best;
    var bestArea = double.infinity;
    viewRects(report, view, shift: shift, anchored: anchored).forEach((i, r) {
      if (report.hazards[i].status != HazardStatus.open) return;
      if (!r.inflate(slop).contains(p)) return;
      final area = r.width * r.height;
      if (area < bestArea) {
        bestArea = area;
        best = i;
      }
    });
    return best;
  }

  /// 스냅샷 기준 0..1 박스 → 화면(view) 픽셀 사각형
  static Rect toView(Rect box, Size image, Size view, Offset shift) {
    final s = math.max(view.width / image.width, view.height / image.height);
    final dw = image.width * s, dh = image.height * s;
    final ox = (view.width - dw) / 2 + shift.dx * view.width;
    final oy = (view.height - dh) / 2 + shift.dy * view.height;
    return Rect.fromLTRB(ox + box.left * dw, oy + box.top * dh,
        ox + box.right * dw, oy + box.bottom * dh);
  }

  /// 화면 밖으로 나간 위험을 가리킬 화살표 위치(가장자리 안쪽)와 방향(라디안, 0 = 오른쪽).
  /// 화면 안에 조금이라도 보이면 null. 화면 가운데에서 위험 쪽으로 그은 선이 가장자리와 만나는 곳
  static (Offset, double)? offscreenArrow(Rect r, Size view,
      {double margin = 28}) {
    if (r.overlaps(Offset.zero & view)) return null;
    final c = view.center(Offset.zero);
    final d = r.center - c;
    if (d == Offset.zero) return null;
    final hx = view.width / 2 - margin, hy = view.height / 2 - margin;
    final t = math.min(d.dx == 0 ? double.infinity : hx / d.dx.abs(),
        d.dy == 0 ? double.infinity : hy / d.dy.abs());
    return (c + d * t, d.direction);
  }

  void _paintArrow(Canvas canvas, Size size, Offset at, double angle,
      Color color, String label) {
    canvas.save();
    canvas.translate(at.dx, at.dy);
    canvas.rotate(angle);
    final tri = Path()
      ..moveTo(16, 0)
      ..lineTo(-12, -14)
      ..lineTo(-12, 14)
      ..close();
    canvas.drawPath(tri, Paint()..color = color);
    canvas.drawPath(
        tri,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = Colors.black);
    canvas.restore();

    // 이름표는 화살표 안쪽(화면 가운데 쪽)에, 화면 밖으로 안 나가게
    final tp = TextPainter(
      text: TextSpan(
          text: '⚠ $label',
          style: const TextStyle(
              color: Colors.black, fontSize: 12, fontWeight: FontWeight.bold)),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: 140);
    final inward = at - Offset.fromDirection(angle, 40);
    final w = tp.width + 8, h = tp.height + 2;
    final bg = Rect.fromLTWH(
        (inward.dx - w / 2).clamp(4, math.max(4, size.width - w - 4)),
        (inward.dy - h / 2).clamp(4, math.max(4, size.height - h - 4)),
        w,
        h);
    canvas.drawRect(bg, Paint()..color = color);
    tp.paint(canvas, Offset(bg.left + 4, bg.top + 1));
  }

  @override
  void paint(Canvas canvas, Size size) {
    final rects = viewRects(report, size,
        shift: shift, anchored: anchored, includeIgnored: showIgnored);
    for (final MapEntry(key: i, value: r) in rects.entries) {
      final h = report.hazards[i];
      final open = h.status == HazardStatus.open;
      final color = switch (h.status) {
        HazardStatus.open => severityColor(h.severity),
        HazardStatus.resolved => resolvedColor,
        HazardStatus.ignored => Colors.grey,
      };
      final arrow = offscreenArrow(r, size);
      if (arrow != null) {
        // 폰을 돌려 위험이 화면 밖으로 나가도 어느 쪽인지 가장자리에 표시(처리 안 된 것만)
        if (open) _paintArrow(canvas, size, arrow.$1, arrow.$2, color, h.type);
        continue;
      }
      final rr = RRect.fromRectAndRadius(r, const Radius.circular(6));
      if (i == selected) {
        canvas.drawRRect(
            rr.inflate(3),
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 8
              ..color = Colors.white);
      }
      canvas.drawRRect(
          rr,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = open ? 4 : 2
            ..color = color);

      final tp = TextPainter(
        text: TextSpan(
            text: switch (h.status) {
              HazardStatus.open => '⚠ ${h.type}',
              HazardStatus.resolved => '✓ ${h.type} 완료',
              HazardStatus.ignored => '${h.type} 무시',
            },
            style: const TextStyle(
                color: Colors.black,
                fontSize: 13,
                fontWeight: FontWeight.bold)),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: math.max(r.width, 120));
      final top = r.bottom + tp.height + 4 < size.height
          ? r.bottom + 2
          : r.top - tp.height - 4;
      final bg = Rect.fromLTWH(r.left, top, tp.width + 8, tp.height + 2);
      canvas.drawRect(bg, Paint()..color = color);
      tp.paint(canvas, Offset(bg.left + 4, bg.top + 1));
    }
  }

  @override
  bool shouldRepaint(HazardBoxPainter old) =>
      old.report != report ||
      old.shift != shift ||
      old.anchored != anchored ||
      old.selected != selected ||
      old.revision != revision ||
      old.showIgnored != showIgnored;
}
