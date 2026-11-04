import 'package:flutter/material.dart';
import '../app/app.dart';
import '../data/models.dart';
import '../ui/inspection_tile.dart';
import 'history_screen.dart';
import 'inspection_detail_screen.dart';
import 'inspection_screen.dart';
import 'settings_screen.dart';

/// 첫 화면: 새 점검 시작 / 진행 중 점검 이어하기 / 최근 기록
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final repo = scope.repo;
    return Scaffold(
      appBar: AppBar(
        title: const Text('시설기사 안전카메라'),
        actions: [
          IconButton(
            tooltip: '설정',
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const SettingsScreen())),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: repo,
        builder: (context, _) {
          final all = repo.inspections;
          final ongoing = all.where((i) => i.inProgress).toList();
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const _AiStatus(),
              const SizedBox(height: 12),
              SizedBox(
                height: 72,
                child: FilledButton.icon(
                  onPressed: () => startInspection(context),
                  icon: const Icon(Icons.photo_camera, size: 32),
                  label: const Text('새 점검 시작', style: TextStyle(fontSize: 22)),
                ),
              ),
              for (final i in ongoing) ...[
                const SizedBox(height: 12),
                Card(
                  color: Colors.red.withValues(alpha: 0.15),
                  child: ListTile(
                    leading: const Icon(Icons.radio_button_checked,
                        color: Colors.redAccent),
                    title: Text('진행 중: ${i.location}'),
                    subtitle:
                        Text('발견 ${i.findings.length}건 · 미조치 ${i.openCount}건'),
                    trailing: FilledButton.tonal(
                      onPressed: () => openInspectionCamera(context, i),
                      child: const Text('이어서'),
                    ),
                    onTap: () => openInspectionDetail(context, i),
                  ),
                ),
              ],
              const SizedBox(height: 24),
              Row(
                children: [
                  Text('최근 점검', style: Theme.of(context).textTheme.titleMedium),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => const HistoryScreen())),
                    child: Text('전체 기록 (${all.length})'),
                  ),
                ],
              ),
              if (all.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 32),
                  child: Center(
                      child: Text('아직 점검 기록이 없습니다.\n"새 점검 시작"을 눌러 보세요.',
                          textAlign: TextAlign.center)),
                ),
              for (final i in all.take(5))
                InspectionTile(i,
                    onTap: () => openInspectionDetail(context, i)),
            ],
          );
        },
      ),
    );
  }
}

/// AI 연결 상태(키 없음·가짜 모드를 현장에서 바로 알 수 있게)
class _AiStatus extends StatelessWidget {
  const _AiStatus();

  @override
  Widget build(BuildContext context) {
    final a = AppScope.of(context).analyzer;
    final reason = a.unavailableReason;
    return Card(
      child: ListTile(
        dense: true,
        leading: Icon(reason == null ? Icons.cloud_done : Icons.cloud_off,
            color: reason == null ? Colors.greenAccent : Colors.orangeAccent),
        title: Text(reason == null ? 'AI 점검 사용 가능' : 'AI 점검 사용 불가'),
        subtitle: Text(reason ?? a.description),
      ),
    );
  }
}

/// 장소를 묻고 새 점검을 만든 뒤 카메라로
Future<void> startInspection(BuildContext context) async {
  final repo = AppScope.of(context).repo;
  final recent = <String>{
    for (final i in repo.inspections)
      if (i.location.isNotEmpty) i.location
  }.take(6).toList();
  final location = await showDialog<String>(
    context: context,
    builder: (_) => _LocationDialog(recent: recent),
  );
  if (location == null || !context.mounted) return;
  final i = await repo.create(location);
  if (context.mounted) await openInspectionCamera(context, i);
}

Future<void> openInspectionCamera(BuildContext context, Inspection i) =>
    Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => InspectionScreen(inspectionId: i.id)));

Future<void> openInspectionDetail(BuildContext context, Inspection i) =>
    Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => InspectionDetailScreen(inspectionId: i.id)));

class _LocationDialog extends StatefulWidget {
  const _LocationDialog({required this.recent});
  final List<String> recent;

  @override
  State<_LocationDialog> createState() => _LocationDialogState();
}

class _LocationDialogState extends State<_LocationDialog> {
  final _c = TextEditingController();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _submit() => Navigator.pop(
      context, _c.text.trim().isEmpty ? '이름 없는 장소' : _c.text.trim());

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('어디를 점검하나요?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _c,
              autofocus: true,
              decoration: const InputDecoration(hintText: '예: B2 기계실, 3층 전기실'),
              onSubmitted: (_) => _submit(),
            ),
            if (widget.recent.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final r in widget.recent)
                    ActionChip(label: Text(r), onPressed: () => _c.text = r),
                ],
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('취소')),
          FilledButton(onPressed: _submit, child: const Text('시작')),
        ],
      );
}
