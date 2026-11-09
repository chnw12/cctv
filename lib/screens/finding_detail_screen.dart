import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import '../analysis/hazard.dart';
import '../app/app.dart';
import '../data/inspection_repository.dart';
import '../ui/analyze_button.dart';
import '../ui/box_painter.dart';
import '../ui/format.dart';
import '../ui/hazard_panel.dart';
import 'inspection_detail_screen.dart' show confirmDelete;

/// 발견사항 하나: 사진 위 위험 위치 + 위험요소 + 조치 완료·메모
class FindingDetailScreen extends StatefulWidget {
  const FindingDetailScreen(
      {super.key, required this.inspectionId, required this.findingId});
  final String inspectionId;
  final String findingId;

  @override
  State<FindingDetailScreen> createState() => _FindingDetailScreenState();
}

class _FindingDetailScreenState extends State<FindingDetailScreen> {
  final _memo = TextEditingController();
  Timer? _memoSave;
  bool _loaded = false;

  /// dispose 중에는 context로 AppScope를 찾을 수 없어 미리 잡아 둠
  late InspectionRepository _repo;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _repo = AppScope.of(context).repo;
  }

  @override
  void dispose() {
    _flushMemo();
    _memo.dispose();
    super.dispose();
  }

  /// 입력이 멈추고 0.6초 뒤 저장(화면을 나갈 때도 저장)
  void _flushMemo() {
    if (_memoSave?.isActive != true) return;
    _memoSave!.cancel();
    _saveMemo();
  }

  void _saveMemo() {
    final repo = _repo;
    final i = repo.byId(widget.inspectionId);
    final f = i?.findings.where((f) => f.id == widget.findingId).firstOrNull;
    if (i != null && f != null && f.memo != _memo.text) {
      repo.updateFinding(i, f, memo: _memo.text);
    }
  }

  @override
  Widget build(BuildContext context) {
    final repo = AppScope.of(context).repo;
    return ListenableBuilder(
      listenable: repo,
      builder: (context, _) {
        final i = repo.byId(widget.inspectionId);
        final f =
            i?.findings.where((f) => f.id == widget.findingId).firstOrNull;
        if (i == null || f == null) {
          return Scaffold(
              appBar: AppBar(), body: const Center(child: Text('삭제된 기록입니다.')));
        }
        if (!_loaded) {
          _memo.text = f.memo;
          _loaded = true;
        }
        final size = f.imageSize;
        return Scaffold(
          appBar: AppBar(
            title: Text('${i.location} · ${fmtTime(f.createdAt)}'),
            actions: [
              IconButton(
                tooltip: '이 기록 삭제',
                icon: const Icon(Icons.delete_outline),
                onPressed: () async {
                  if (!await confirmDelete(context, '이 사진과 기록을 삭제할까요?')) {
                    return;
                  }
                  _memoSave?.cancel();
                  if (context.mounted) Navigator.pop(context);
                  await repo.deleteFinding(i, f);
                },
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              // 사진은 화면 높이의 45%까지만 → 메모·조치 완료가 스크롤 없이 보이게
              ConstrainedBox(
                constraints: BoxConstraints(
                    maxHeight: MediaQuery.sizeOf(context).height * 0.45),
                child: Center(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: AspectRatio(
                      aspectRatio: size.width > 0 && size.height > 0
                          ? size.width / size.height
                          : 3 / 4,
                      child: GestureDetector(
                        onTap: () => _openFullPhoto(
                            context, repo.photoFile(i, f), f.report),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            Image.file(repo.photoFile(i, f),
                                fit: BoxFit.fill,
                                errorBuilder: (_, __, ___) => const Center(
                                    child: Icon(Icons.broken_image))),
                            // 사진과 분석 이미지가 같은 크기라 박스가 그대로 맞음
                            CustomPaint(
                                painter: HazardBoxPainter(f.report,
                                    showIgnored: true,
                                    revision: _statusSig(f.report))),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              // 인터넷 없던 곳에서 사진만 남겼으면 지금 AI로 분석
              if (f.needsAi)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: AnalyzeButton(i, finding: f),
                ),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: HazardList(f.report,
                      // 사진만 남긴 기록은 아직 AI가 안 봤으므로 "위험 없음"이라고 하지 않음
                      emptyText: f.needsAi
                          ? 'AI 분석 전 사진 · 위 버튼으로 분석'
                          : HazardList.noHazardText,
                      below: (idx, h) => _HazardStatusRow(
                            hazard: h,
                            afterPhoto: repo.afterPhotoFile(i, h),
                            onSet: (s) =>
                                repo.setHazardStatus(i, f, idx, s, by: 'list'),
                          )),
                ),
              ),
              SwitchListTile(
                title: const Text('조치 완료'),
                subtitle: Text(f.allIgnored
                    ? 'AI가 짚은 위험을 모두 오탐으로 처리함'
                    : f.done
                        ? '조치가 끝난 항목입니다'
                        : '아직 조치가 필요합니다'),
                value: f.finished,
                onChanged: (v) => repo.updateFinding(i, f, resolved: v),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _memo,
                minLines: 3,
                maxLines: 8,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: '메모',
                  hintText: '조치 내용, 담당자, 부품 번호 등',
                ),
                onChanged: (_) {
                  _memoSave?.cancel();
                  _memoSave =
                      Timer(const Duration(milliseconds: 600), _saveMemo);
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 처리 상태가 바뀌면 달라지는 값(같은 결과 객체라도 사진 위 박스를 다시 그리게)
int _statusSig(HazardReport r) =>
    r.hazards.fold(0, (a, h) => a * 3 + h.status.index);

/// 위험 하나 아래: 처리 안 됐으면 [완료] [무시], 처리됐으면 언제·어떻게 + 조치 후 사진 + [되돌리기]
class _HazardStatusRow extends StatelessWidget {
  const _HazardStatusRow(
      {required this.hazard, required this.afterPhoto, required this.onSet});
  final Hazard hazard;
  final File? afterPhoto;
  final void Function(HazardStatus) onSet;

  static String _how(String? by) => switch (by) {
        'tap' => '카메라 화면에서',
        'hand' => '카메라 화면에서 손으로',
        'list' => '기록 화면에서',
        _ => '',
      };

  @override
  Widget build(BuildContext context) {
    final h = hazard;
    if (h.status == HazardStatus.open) {
      return Padding(
        padding: const EdgeInsets.only(left: 40),
        child: Wrap(
          spacing: 8,
          children: [
            TextButton.icon(
              onPressed: () => onSet(HazardStatus.resolved),
              icon: const Icon(Icons.check),
              label: const Text('완료'),
            ),
            TextButton.icon(
              // 카메라 화면과 같게: 위험 등급은 오탐인지 한 번 더 확인
              onPressed: () async {
                if (h.severity == Severity.high &&
                    !await confirmIgnoreHigh(context, h)) {
                  return;
                }
                onSet(HazardStatus.ignored);
              },
              icon: const Icon(Icons.visibility_off),
              label: const Text('무시'),
            ),
          ],
        ),
      );
    }
    final photo = afterPhoto;
    return Padding(
      padding: const EdgeInsets.only(left: 40, top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                    [
                      if (h.statusAt != null) fmtFull(h.statusAt!),
                      _how(h.statusBy),
                      h.status == HazardStatus.resolved ? '완료' : '무시',
                    ].where((s) => s.isNotEmpty).join(' · '),
                    style:
                        const TextStyle(color: Colors.white54, fontSize: 12)),
              ),
              TextButton(
                  onPressed: () => onSet(HazardStatus.open),
                  child: const Text('되돌리기')),
            ],
          ),
          if (photo != null)
            GestureDetector(
              onTap: () => _openFullPhoto(context, photo, null),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.file(photo,
                    height: 140,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) =>
                        const Icon(Icons.broken_image)),
              ),
            ),
          if (photo != null)
            const Padding(
              padding: EdgeInsets.only(top: 2),
              child: Text('조치 후 사진',
                  style: TextStyle(color: Colors.white54, fontSize: 11)),
            ),
        ],
      ),
    );
  }
}

/// 사진 전체 화면(두 손가락으로 확대 — 계기 눈금·명판 확인용). report가 없으면 박스 없이(조치 후 사진)
void _openFullPhoto(BuildContext context, File photo, HazardReport? report) {
  if (report == null) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(backgroundColor: Colors.black),
          body: InteractiveViewer(
              maxScale: 6, child: Center(child: Image.file(photo))),
        ),
      ),
    );
    return;
  }
  final size = report.imageSize;
  Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(backgroundColor: Colors.black),
        body: InteractiveViewer(
          maxScale: 6,
          child: Center(
            child: AspectRatio(
              aspectRatio: size.width > 0 && size.height > 0
                  ? size.width / size.height
                  : 3 / 4,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Image.file(photo, fit: BoxFit.fill),
                  CustomPaint(
                      painter: HazardBoxPainter(report, showIgnored: true)),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
