import 'package:flutter/material.dart';
import '../analysis/hazard.dart';
import '../camera/camera_pipeline.dart';

Color severityColor(Severity s) => switch (s) {
      Severity.high => Colors.redAccent,
      Severity.medium => Colors.orangeAccent,
      Severity.low => Colors.yellowAccent,
    };

String severityLabel(Severity s) => switch (s) {
      Severity.high => '위험',
      Severity.medium => '주의',
      Severity.low => '관찰',
    };

/// 심각도 배지(위험·주의·관찰)
class SeverityBadge extends StatelessWidget {
  const SeverityBadge(this.severity, {super.key, this.count});
  final Severity severity;
  final int? count;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
            color: severityColor(severity),
            borderRadius: BorderRadius.circular(4)),
        child: Text(
            count == null
                ? severityLabel(severity)
                : '${severityLabel(severity)} $count',
            style: const TextStyle(
                color: Colors.black,
                fontSize: 12,
                fontWeight: FontWeight.bold)),
      );
}

/// 위험 처리 상태 표시(완료·무시)
class StatusChip extends StatelessWidget {
  const StatusChip(this.status, {super.key});
  final HazardStatus status;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(right: 6),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
            color: status == HazardStatus.resolved
                ? Colors.greenAccent
                : Colors.grey,
            borderRadius: BorderRadius.circular(4)),
        child: Text(status == HazardStatus.resolved ? '✓ 완료' : '무시',
            style: const TextStyle(
                color: Colors.black,
                fontSize: 11,
                fontWeight: FontWeight.bold,
                decoration: TextDecoration.none)),
      );
}

/// 위험요소 목록(심각도 높은 순). 결과 패널·발견사항 상세에서 같이 씀.
/// 완료·무시한 위험은 상태 표시와 함께 흐리게. [below]로 위험마다 아래에 버튼 등을 붙임(기록 화면)
class HazardList extends StatelessWidget {
  const HazardList(this.report, {super.key, this.below});
  final HazardReport report;
  final Widget Function(int index, Hazard h)? below;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(report.summary,
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          if (report.hazards.isEmpty)
            const Text('발견된 위험요소 없음',
                style: TextStyle(color: Colors.greenAccent)),
          for (final (i, h) in report.hazards.indexed)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SeverityBadge(h.severity),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text.rich(
                          TextSpan(children: [
                            if (h.status != HazardStatus.open)
                              WidgetSpan(
                                  alignment: PlaceholderAlignment.middle,
                                  child: StatusChip(h.status)),
                            TextSpan(
                                text: '${h.type}  ',
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold)),
                            TextSpan(text: h.description),
                            TextSpan(
                                text: '\n→ ${h.action}',
                                style: const TextStyle(
                                    color: Colors.lightBlueAccent)),
                          ]),
                          style: TextStyle(
                              color: h.status == HazardStatus.open
                                  ? Colors.white
                                  : Colors.white54,
                              fontSize: 13,
                              decoration: h.status == HazardStatus.ignored
                                  ? TextDecoration.lineThrough
                                  : null),
                        ),
                      ),
                    ],
                  ),
                  if (below != null) below!(i, h),
                ],
              ),
            ),
        ],
      );
}

/// 카메라 위 하단에 뜨는 AI 점검 결과. footer에 "기록 저장" 같은 버튼을 넣을 수 있음
class HazardPanel extends StatelessWidget {
  const HazardPanel(
      {super.key, required this.state, required this.onClose, this.footer});
  final AiState state;
  final VoidCallback onClose;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final r = state.report;
    final Widget body;
    if (state.error != null) {
      body = Text(state.error!,
          style: const TextStyle(color: Colors.redAccent, fontSize: 13));
    } else if (r == null) {
      body = Text(state.auto ? '새 물체 발견 → 자동 AI 점검 중…' : 'AI 점검 중…',
          style: const TextStyle(color: Colors.white70));
    } else {
      body = HazardList(r);
    }

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8),
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 10),
      constraints:
          BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.4),
      decoration: BoxDecoration(
          color: Colors.black87, borderRadius: BorderRadius.circular(10)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: SingleChildScrollView(child: body)),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                        onPressed: onClose,
                        icon: const Icon(Icons.close, color: Colors.white54)),
                    if (r != null)
                      Text(
                          [
                            if (state.snapshotMs != null)
                              '촬영 ${(state.snapshotMs! / 1000).toStringAsFixed(1)}s',
                            'AI ${(r.elapsedMs / 1000).toStringAsFixed(1)}s',
                          ].join('\n'),
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              color: Colors.white54, fontSize: 11)),
                  ],
                ),
              ],
            ),
          ),
          if (footer != null) footer!,
        ],
      ),
    );
  }
}
