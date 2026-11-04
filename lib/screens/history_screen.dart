import 'package:flutter/material.dart';
import '../app/app.dart';
import '../data/models.dart';
import '../ui/inspection_tile.dart';
import 'home_screen.dart' show openInspectionDetail;
import 'inspection_detail_screen.dart' show confirmDelete;

enum _Filter { all, ongoing, open }

/// 전체 점검 기록(최신순). 길게 누르면 삭제
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  _Filter _filter = _Filter.all;

  bool _match(Inspection i) => switch (_filter) {
        _Filter.all => true,
        _Filter.ongoing => i.inProgress,
        _Filter.open => i.openCount > 0,
      };

  @override
  Widget build(BuildContext context) {
    final repo = AppScope.of(context).repo;
    return Scaffold(
      appBar: AppBar(title: const Text('점검 기록')),
      body: ListenableBuilder(
        listenable: repo,
        builder: (context, _) {
          final list = repo.inspections.where(_match).toList();
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(8),
                child: SegmentedButton<_Filter>(
                  segments: const [
                    ButtonSegment(value: _Filter.all, label: Text('전체')),
                    ButtonSegment(value: _Filter.ongoing, label: Text('진행 중')),
                    ButtonSegment(value: _Filter.open, label: Text('미조치 있음')),
                  ],
                  selected: {_filter},
                  onSelectionChanged: (s) => setState(() => _filter = s.first),
                ),
              ),
              Expanded(
                child: list.isEmpty
                    ? const Center(child: Text('해당하는 점검이 없습니다.'))
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        itemCount: list.length,
                        itemBuilder: (_, n) {
                          final i = list[n];
                          return InspectionTile(
                            i,
                            onTap: () => openInspectionDetail(context, i),
                            onLongPress: () async {
                              if (await confirmDelete(context,
                                  '"${i.location}" 점검을 삭제할까요? 되돌릴 수 없습니다.')) {
                                await repo.delete(i);
                              }
                            },
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}
