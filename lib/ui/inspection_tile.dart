import 'package:flutter/material.dart';
import '../analysis/hazard.dart';
import '../data/models.dart';
import 'format.dart';
import 'hazard_panel.dart';

/// 점검 한 건 요약 줄(홈·기록 목록 공용)
class InspectionTile extends StatelessWidget {
  const InspectionTile(this.inspection,
      {super.key, this.onTap, this.onLongPress});
  final Inspection inspection;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final i = inspection;
    final open = i.openBySeverity;
    return Card(
      child: ListTile(
        onTap: onTap,
        onLongPress: onLongPress,
        leading: Icon(
            i.inProgress
                ? Icons.radio_button_checked
                : Icons.assignment_turned_in,
            color: i.inProgress ? Colors.redAccent : null),
        title: Text(i.location.isEmpty ? '(장소 없음)' : i.location),
        subtitle: Text('${fmtDateTime(i.startedAt)}'
            '${i.inProgress ? ' · 진행 중' : ''} · 발견 ${i.findings.length}건'),
        trailing: Wrap(
          spacing: 4,
          children: [
            for (final s in Severity.values)
              if (open[s]! > 0) SeverityBadge(s, count: open[s]),
          ],
        ),
      ),
    );
  }
}
