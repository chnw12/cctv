import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/app_log.dart';
import '../analysis/hazard.dart';
import '../app/app.dart';
import '../data/models.dart';
import '../data/report_text.dart';
import '../data/share_report.dart';
import '../ui/analyze_button.dart';
import '../ui/format.dart';
import '../ui/hazard_panel.dart';
import 'finding_detail_screen.dart';
import 'inspection_screen.dart';

/// 점검 한 건: 요약 + 발견사항 목록(최신순). 진행 중이면 이어서 점검·종료 가능
class InspectionDetailScreen extends StatelessWidget {
  const InspectionDetailScreen(
      {super.key, required this.inspectionId, this.fromCamera = false});
  final String inspectionId;

  /// 점검 카메라 화면에서 열었으면 "이어서 점검"은 새 카메라 화면이 아니라 뒤로 가기
  final bool fromCamera;

  @override
  Widget build(BuildContext context) {
    final repo = AppScope.of(context).repo;
    return ListenableBuilder(
      listenable: repo,
      builder: (context, _) {
        final i = repo.byId(inspectionId);
        if (i == null) {
          return Scaffold(
              appBar: AppBar(), body: const Center(child: Text('삭제된 점검입니다.')));
        }
        final findings = i.findings.reversed.toList();
        return Scaffold(
          appBar: AppBar(
            title: Text(i.location),
            actions: [
              _ShareButton(i),
              PopupMenuButton<String>(
                onSelected: (v) => switch (v) {
                  'copy' => _copy(context, i),
                  'csv' => shareInspectionCsv(i),
                  'rename' => _rename(context, i),
                  'delete' => _delete(context, i),
                  _ => null,
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'copy', child: Text('요약 글만 복사')),
                  PopupMenuItem(value: 'csv', child: Text('CSV(엑셀)로 내보내기')),
                  PopupMenuItem(value: 'rename', child: Text('장소 이름 바꾸기')),
                  PopupMenuItem(value: 'delete', child: Text('점검 삭제')),
                ],
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              _Summary(i),
              if (i.inProgress)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: () => fromCamera
                              ? Navigator.pop(context)
                              : Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                      builder: (_) => InspectionScreen(
                                          inspectionId: i.id))),
                          icon: const Icon(Icons.photo_camera),
                          label: const Text('이어서 점검'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () async {
                            await repo.finish(i);
                            // 카메라에서 왔으면 끝난 점검의 카메라 화면으로 돌아가지 않게 홈 → 상세로
                            if (fromCamera && context.mounted) {
                              final nav = Navigator.of(context)
                                ..popUntil((r) => r.isFirst);
                              nav.push(MaterialPageRoute(
                                  builder: (_) => InspectionDetailScreen(
                                      inspectionId: i.id)));
                            }
                          },
                          icon: const Icon(Icons.stop_circle),
                          label: const Text('점검 종료'),
                        ),
                      ),
                    ],
                  ),
                ),
              if (i.findings.any((f) => f.needsAi))
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: AnalyzeButton(i),
                ),
              const SizedBox(height: 12),
              if (findings.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: Text('기록된 발견사항이 없습니다.')),
                )
              else
                _FindingList(i, findings),
            ],
          ),
        );
      },
    );
  }

  Future<void> _copy(BuildContext context, Inspection i) async {
    await Clipboard.setData(ClipboardData(text: inspectionReportText(i)));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('점검 요약을 복사했습니다(메신저·일지에 붙여넣기)')));
    }
  }

  Future<void> _rename(BuildContext context, Inspection i) async {
    final c = TextEditingController(text: i.location);
    final name = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('장소 이름'),
        content: TextField(controller: c, autofocus: true),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('취소')),
          FilledButton(
              onPressed: () => Navigator.pop(context, c.text),
              child: const Text('저장')),
        ],
      ),
    );
    c.dispose();
    if (name != null && name.trim().isNotEmpty && context.mounted) {
      await AppScope.of(context).repo.rename(i, name);
    }
  }

  Future<void> _delete(BuildContext context, Inspection i) async {
    final ok = await confirmDelete(context,
        '"${i.location}" 점검과 사진 ${i.findings.length}장을 삭제할까요? 되돌릴 수 없습니다.');
    if (!ok || !context.mounted) return;
    final repo = AppScope.of(context).repo;
    Navigator.pop(context);
    await repo.delete(i);
  }
}

Future<bool> confirmDelete(BuildContext context, String message) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('삭제'),
        content: Text(message),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('취소')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('삭제')),
        ],
      ),
    ) ==
    true;

class _Summary extends StatelessWidget {
  const _Summary(this.i);
  final Inspection i;

  @override
  Widget build(BuildContext context) {
    final open = i.openBySeverity;
    final end = i.endedAt;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('시작 ${fmtFull(i.startedAt)}'),
            Text(end == null
                ? '진행 중'
                : '종료 ${fmtFull(end)} (${fmtDuration(end.difference(i.startedAt))})'),
            const SizedBox(height: 8),
            Text('발견 ${i.findings.length}건 · 미조치 ${i.openCount}건',
                style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Wrap(spacing: 6, children: [
              for (final s in Severity.values)
                if (open[s]! > 0) SeverityBadge(s, count: open[s]),
            ]),
          ],
        ),
      ),
    );
  }
}

class _FindingTile extends StatelessWidget {
  const _FindingTile(this.i, this.f);
  final Inspection i;
  final Finding f;

  static String sourceLabel(FindingSource s) => switch (s) {
        FindingSource.ai => 'AI 점검',
        FindingSource.auto => '자동 점검',
        FindingSource.manual => '직접 기록',
      };

  @override
  Widget build(BuildContext context) {
    final repo = AppScope.of(context).repo;
    final worst = f.worst;
    return Card(
      child: InkWell(
        onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) =>
                    FindingDetailScreen(inspectionId: i.id, findingId: f.id))),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.file(repo.photoFile(i, f),
                    width: 72,
                    height: 96,
                    fit: BoxFit.cover,
                    cacheWidth: 144,
                    errorBuilder: (_, __, ___) => const SizedBox(
                        width: 72,
                        height: 96,
                        child: Icon(Icons.broken_image))),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      if (worst != null) SeverityBadge(worst),
                      if (worst != null) const SizedBox(width: 6),
                      Text('${fmtTime(f.createdAt)} · ${sourceLabel(f.source)}',
                          style: Theme.of(context).textTheme.bodySmall),
                    ]),
                    const SizedBox(height: 4),
                    Text(f.report.summary,
                        maxLines: 2, overflow: TextOverflow.ellipsis),
                    if (f.report.hazards.isNotEmpty)
                      Text(f.report.hazards.map((h) => h.type).join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall),
                    if (f.memo.isNotEmpty)
                      Text('메모: ${f.memo}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style:
                              const TextStyle(color: Colors.lightBlueAccent)),
                  ],
                ),
              ),
              IconButton(
                tooltip: f.done ? '조치 완료 취소' : '조치 완료',
                onPressed: () => repo.updateFinding(i, f, resolved: !f.done),
                icon: Icon(
                    f.done ? Icons.check_circle : Icons.radio_button_unchecked,
                    color: f.done ? Colors.greenAccent : null),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 위험 표시한 사진 + 요약을 공유. 사진을 그리는 동안 돌아가는 표시
class _ShareButton extends StatefulWidget {
  const _ShareButton(this.i);
  final Inspection i;

  @override
  State<_ShareButton> createState() => _ShareButtonState();
}

class _ShareButtonState extends State<_ShareButton> {
  bool _busy = false;

  Future<void> _share() async {
    setState(() => _busy = true);
    try {
      await shareInspection(AppScope.of(context).repo, widget.i);
    } catch (e, st) {
      AppLog.error('점검 공유 실패', e, st);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('공유 실패: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: '사진과 함께 공유',
        onPressed: _busy ? null : _share,
        icon: _busy
            ? const SizedBox.square(
                dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.share),
      );
}

enum _Order { time, risk }

/// 발견 목록: 시간순(최신 먼저) / 위험순(미조치·심각한 것 먼저) — 보고할 때는 위험순이 편함
class _FindingList extends StatefulWidget {
  const _FindingList(this.i, this.byTime);
  final Inspection i;
  final List<Finding> byTime; // 최신 먼저

  @override
  State<_FindingList> createState() => _FindingListState();
}

class _FindingListState extends State<_FindingList> {
  _Order _order = _Order.time;

  /// 미조치가 먼저, 그 안에서 가장 높은 심각도 순(위험 없는 기록은 맨 뒤)
  static int _rank(Finding f) => (f.done ? 10 : 0) + (f.worst?.index ?? 5);

  @override
  Widget build(BuildContext context) {
    final list = _order == _Order.time
        ? widget.byTime
        : ([...widget.byTime]..sort((a, b) => _rank(a).compareTo(_rank(b))));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: SegmentedButton<_Order>(
            segments: const [
              ButtonSegment(value: _Order.time, label: Text('시간순')),
              ButtonSegment(value: _Order.risk, label: Text('위험순')),
            ],
            selected: {_order},
            onSelectionChanged: (s) => setState(() => _order = s.first),
          ),
        ),
        const SizedBox(height: 4),
        for (final f in list) _FindingTile(widget.i, f),
      ],
    );
  }
}
