import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../core/app_log.dart';
import '../analysis/hazard.dart';
import '../app/app.dart';
import '../camera/camera_pipeline.dart';
import '../camera/auto_save_guard.dart';
import '../camera/camera_view.dart';
import '../camera/volume_keys.dart';
import '../data/models.dart';
import '../ui/hazard_panel.dart';
import '../ui/inspection_overlays.dart';
import 'finding_detail_screen.dart';
import 'inspection_detail_screen.dart';

/// 점검 중 카메라 화면.
/// - AI 점검: 지금 장면을 찍어 위험요소 분석 → "기록 저장"으로 발견사항에 추가
/// - 자동: 새 물체가 나타나면 AI 점검, 위험이 나오면 설정에 따라 자동 저장
/// - 사진 기록: AI 없이 사진만(인터넷 안 될 때·직접 메모)
/// - 위험 박스를 누르면 [무시] [완료] → 그 위험의 처리 상태 기록(완료면 조치 후 사진도)
class InspectionScreen extends StatefulWidget {
  const InspectionScreen({super.key, required this.inspectionId});
  final String inspectionId;

  @override
  State<InspectionScreen> createState() => _InspectionScreenState();
}

class _InspectionScreenState extends State<InspectionScreen> with RouteAware {
  late final AppScope _scope;
  late final CameraPipeline _p;
  late final Inspection _inspection;
  bool _ready = false;

  /// 이미 저장한 AI 결과 → 그 발견사항(같은 결과를 두 번 저장하지 않게, 무시·완료를 기록할 곳)
  final _saved = <AiState, Finding>{};
  final _guard = AutoSaveGuard();
  bool _saving = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_ready) return; // AppScope는 바뀌지 않으므로 처음 한 번만
    final route = ModalRoute.of(context);
    if (route is PageRoute) appRouteObserver.subscribe(this, route);
    _scope = AppScope.of(context);
    _inspection = _scope.repo.byId(widget.inspectionId)!;
    _p = CameraPipeline(settings: _scope.settings, analyzer: _scope.analyzer)
      ..onAiResult = _onAiResult
      ..place = _inspection.location
      ..open(SourceKind.camera);
    _ready = true;
    // 카메라를 들고 점검하는 동안 화면이 꺼지지 않게(지원 안 하는 기기는 무시)
    WakelockPlus.enable().catchError((_) {});
    _listenVolumeKeys();
    _bumpIdle();
  }

  // ── 안 쓰면 일시정지(배터리) ──
  Timer? _idleTimer;
  bool _paused = false;

  /// 화면을 만지거나 볼륨 키를 누를 때마다 다시 셈
  void _bumpIdle() {
    _idleTimer?.cancel();
    final m = _scope.settings.idlePauseMin;
    if (m > 0 && !_paused) _idleTimer = Timer(Duration(minutes: m), _pause);
  }

  void _pause() {
    if (!mounted || _paused) return;
    setState(() => _paused = true);
    _p.close();
    WakelockPlus.disable().catchError((_) {});
  }

  void _resume() {
    if (!_paused) return;
    setState(() => _paused = false);
    _p.open(SourceKind.camera);
    WakelockPlus.enable().catchError((_) {});
    _bumpIdle();
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    appRouteObserver.unsubscribe(this);
    VolumeKeys.stop();
    WakelockPlus.disable().catchError((_) {});
    if (_ready) _p.dispose();
    super.dispose();
  }

  /// 장갑 낀 채로도 누를 수 있게 볼륨 키 = AI 점검(이 화면이 맨 위일 때만, 시스템 음량은 안 바뀜)
  void _listenVolumeKeys() => VolumeKeys.listen(() {
        if (_paused) return _resume(); // 멈춰 있으면 먼저 깨우기
        _bumpIdle();
        if (_p.source != null && _p.ai.value?.running != true) _p.runAi();
      });

  // 발견사항 화면 등을 위에 띄우면 볼륨 키를 원래대로, 돌아오면 다시 AI 점검으로
  @override
  void didPushNext() {
    // 다른 화면(발견 목록·상세)에 가려지면 카메라를 끔: 배터리 절약 + 그 화면에서
    // "이어서 점검"으로 카메라 화면이 또 열려도 카메라를 두고 다투지 않게
    VolumeKeys.stop();
    _idleTimer?.cancel();
    _p.close();
  }

  @override
  void didPopNext() {
    _listenVolumeKeys();
    if (_paused) return; // 멈춘 채로 나갔으면 그대로(탭하면 재개)
    _p.open(SourceKind.camera);
    _bumpIdle();
  }

  /// 1배 → 2배 → 최대 → 1배 (장갑 끼면 두 손가락 확대가 어려워 버튼으로도)
  Future<void> _cycleZoom() async {
    final c = _p.controls;
    if (c == null) return;
    final steps = <double>{1, 2, c.maxZoom}
        .where((z) => z >= c.minZoom && z <= c.maxZoom)
        .toList()
      ..sort();
    final next =
        steps.firstWhere((z) => z > c.zoom + 0.05, orElse: () => steps.first);
    try {
      await _p.setZoom(next);
    } catch (_) {
      _toast('이 카메라는 줌을 지원하지 않습니다');
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
          content: Text(msg),
          duration: const Duration(seconds: 2),
          // 아래 버튼(AI 점검 등)을 가리지 않게 위로 띄움
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 130)));
  }

  /// 자동 점검에서 위험이 나오면 설정에 따라 바로 저장
  void _onAiResult(AiState s) {
    final r = s.report;
    // 시끄러운 기계실에서도 알 수 있게 위험이 나오면 진동(위험=강하게)
    if (r != null && r.hazards.isNotEmpty) {
      r.worst == Severity.high
          ? HapticFeedback.heavyImpact()
          : HapticFeedback.mediumImpact();
    }
    if (s.auto &&
        r != null &&
        r.hazards.isNotEmpty &&
        _scope.settings.autoSaveHazards) {
      // 같은 위험을 1분 안에 또 저장하지 않음(폰을 움직이면 같은 물체가 새 ID로 다시 잡힘)
      if (_guard.shouldSave(r)) {
        _save(s, FindingSource.auto);
      } else {
        // 종류 이름만 비교하므로 다른 설비의 같은 종류 위험일 수도 있음 → 직접 저장할 길을 알려 줌
        _toast('같은 종류 위험을 1분 안에 저장해서 자동 저장 건너뜀 · 다른 위험이면 [기록 저장]');
      }
    }
  }

  /// 저장한 발견사항(이미 저장했으면 그것, 다른 저장 중이거나 실패하면 null).
  /// quiet: 무시·완료가 자기 안내를 띄우므로 "저장됨" 안내 생략
  Future<Finding?> _save(AiState s, FindingSource source,
      {bool quiet = false}) async {
    if (_saved[s] case final f?) return f;
    if (_saving || s.jpeg == null || s.report == null) return null;
    setState(() => _saving = true);
    try {
      final f =
          await _scope.repo.addFinding(_inspection, s.jpeg!, s.report!, source);
      // 직접 저장한 위험도 기억 → 곧바로 자동 점검이 같은 걸 또 저장하지 않게
      if (source != FindingSource.auto) _guard.shouldSave(s.report!);
      _saved[s] = f;
      if (!quiet) {
        _toast(source == FindingSource.auto ? '위험요소 자동 저장됨' : '기록 저장됨');
      }
      return f;
    } catch (e, st) {
      AppLog.error('기록 저장 실패', e, st);
      _toast('저장 실패: $e');
      return null;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 위험 박스의 [무시] [완료]. 결과가 아직 기록이 아니면 먼저 저장(처리한 것도 기록·분석 데이터로 남게),
  /// 완료면 지금 화면을 조치 후 사진으로 같이 저장. 3초 동안 되돌리기
  Future<void> _onHazardAction(
      int index, HazardStatus action, String by) async {
    final s = _p.ai.value;
    final r = s?.report;
    if (s == null || r == null || index >= r.hazards.length) return;
    final h = r.hazards[index];
    if (action == HazardStatus.ignored &&
        h.severity == Severity.high &&
        !await confirmIgnoreHigh(context, h)) {
      return;
    }
    final f = await _save(s, s.auto ? FindingSource.auto : FindingSource.ai,
        quiet: true);
    if (f == null) {
      _toast('기록을 저장하지 못해 처리하지 않았습니다. 다시 눌러 주세요');
      return;
    }
    Uint8List? after;
    if (action == HazardStatus.resolved) {
      try {
        after = await _p.capturePhoto();
      } catch (_) {
        // 카메라가 닫혔으면 사진 없이 완료만 기록
      }
    }
    try {
      await _scope.repo.setHazardStatus(_inspection, f, index, action,
          by: by, afterJpeg: after);
    } catch (e, st) {
      AppLog.error('위험 처리 기록 실패', e, st);
      _toast('처리 기록 실패: $e');
      return;
    }
    _p.markHazardsChanged();
    HapticFeedback.mediumImpact();
    if (!mounted) return;
    final what = action == HazardStatus.resolved
        ? '"${h.type}" 조치 완료${after != null ? ' · 조치 후 사진 저장' : ''}'
        : '"${h.type}" 무시함';
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(what),
        duration: const Duration(seconds: 3),
        // 버튼이 있는 안내는 기본으로 안 사라짐 → 결과 패널을 계속 가려서(에뮬레이터 확인) 3초 뒤 닫히게
        persist: false,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 130),
        action: SnackBarAction(
          label: '되돌리기',
          onPressed: () async {
            await _scope.repo.setHazardStatus(
                _inspection, f, index, HazardStatus.open,
                by: by);
            _p.markHazardsChanged();
          },
        ),
      ));
  }

  /// AI 분석에 실패한 사진을 "미분석 기록"으로 저장(점검 상세에서 한꺼번에 분석)
  Future<void> _saveFailedShot(AiState s) async {
    setState(() => _saving = true);
    try {
      _saved[s] = await _scope.repo.addFinding(
          _inspection,
          s.jpeg!,
          const HazardReport(
              summary: Finding.manualSummary,
              hazards: [],
              elapsedMs: 0,
              imageSize: Size.zero),
          FindingSource.manual);
      _toast('사진 저장됨 — 인터넷 되는 곳에서 "미분석 사진 AI 분석"');
    } catch (e, st) {
      AppLog.error('사진만 저장 실패', e, st);
      _toast('저장 실패: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// AI 없이 사진만 기록 → 상세 화면에서 메모
  Future<void> _photoOnly() async {
    setState(() => _saving = true);
    try {
      final jpeg = await _p.capturePhoto();
      final f = await _scope.repo.addFinding(
          _inspection,
          jpeg,
          const HazardReport(
              summary: Finding.manualSummary,
              hazards: [],
              elapsedMs: 0,
              imageSize: Size.zero),
          FindingSource.manual);
      if (!mounted) return;
      _toast('사진 저장됨 — 메모를 남겨 주세요');
      await Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => FindingDetailScreen(
                  inspectionId: _inspection.id, findingId: f.id)));
    } catch (e, st) {
      AppLog.error('직접 기록 사진 실패', e, st);
      _toast('사진 저장 실패: ${e is StateError ? e.message : e}');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _toggleTorch() async {
    final c = _p.controls;
    if (c == null) return;
    try {
      await _p.setTorch(!c.torchOn);
    } catch (_) {
      _toast('이 카메라는 플래시(손전등)를 지원하지 않습니다');
    }
  }

  Future<void> _finish() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('점검을 마칠까요?'),
        content: Text('발견 ${_inspection.findings.length}건이 기록되어 있습니다.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('계속 점검')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('점검 종료')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _scope.repo.finish(_inspection);
    if (!mounted) return;
    Navigator.pushReplacement(
        context,
        MaterialPageRoute(
            builder: (_) =>
                InspectionDetailScreen(inspectionId: _inspection.id)));
  }

  void _openFindings() => Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) => InspectionDetailScreen(
              inspectionId: _inspection.id, fromCamera: true)));

  @override
  Widget build(BuildContext context) {
    final settings = _scope.settings;
    return Scaffold(
      backgroundColor: Colors.black,
      // 어디든 만지면 일시정지 타이머를 다시 셈
      body: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => _bumpIdle(),
        child: Stack(
          children: [
            ListenableBuilder(
              listenable: settings,
              builder: (_, __) => CameraView(
                  pipeline: _p,
                  showDetections: settings.showDetections,
                  onHazardAction: _onHazardAction),
            ),
            SafeArea(child: _topBar()),
            // 어두우면 손전등 권유(기계실·전기실은 어두운 곳이 많음)
            SafeArea(
              child: Align(
                alignment: Alignment.topCenter,
                child: Padding(
                  padding: const EdgeInsets.only(top: 64),
                  child: ListenableBuilder(
                    listenable: Listenable.merge([_p, _p.isDark]),
                    builder: (_, __) {
                      final c = _p.controls;
                      if (!_p.isDark.value || c == null || c.torchOn) {
                        return const SizedBox.shrink();
                      }
                      return ActionChip(
                        avatar: const Icon(Icons.flashlight_on, size: 18),
                        label: const Text('어두워요 · 손전등 켜기'),
                        onPressed: _toggleTorch,
                      );
                    },
                  ),
                ),
              ),
            ),
            SafeArea(
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 무시·완료하면 목록의 상태 표시도 바뀌게
                      ListenableBuilder(
                        listenable:
                            Listenable.merge([_p.ai, _p.hazardRevision]),
                        builder: (_, __) {
                          final s = _p.ai.value;
                          return s == null
                              ? const SizedBox.shrink()
                              : HazardPanel(
                                  state: s,
                                  onClose: _p.clearAi,
                                  footer: _panelFooter(s));
                        },
                      ),
                      const SizedBox(height: 10),
                      _bottomBar(),
                    ],
                  ),
                ),
              ),
            ),
            // 처음 한 번: 숨은 조작법 안내(볼륨 키·탭 초점·확대·사진만 기록)
            ListenableBuilder(
              listenable: settings,
              builder: (_, __) => settings.seenCameraTips
                  ? const SizedBox.shrink()
                  : SafeArea(
                      child: Align(
                        alignment: Alignment.center,
                        child: CameraTipsCard(
                            onClose: () => settings
                                .update((s) => s.seenCameraTips = true)),
                      ),
                    ),
            ),
            if (_paused)
              Positioned.fill(child: PausedOverlay(onResume: _resume)),
          ],
        ),
      ),
    );
  }

  Widget _topBar() => Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          children: [
            _round(IconButton(
                tooltip: '나가기(점검은 진행 중으로 남음)',
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.arrow_back, color: Colors.white))),
            const SizedBox(width: 8),
            Expanded(
              child: _round(Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Text(_inspection.location,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.bold)),
              )),
            ),
            const SizedBox(width: 8),
            ListenableBuilder(
              listenable: _scope.repo,
              builder: (_, __) => _round(TextButton.icon(
                onPressed: _openFindings,
                icon: const Icon(Icons.list_alt, color: Colors.white),
                label: Text('${_inspection.findings.length}',
                    style: const TextStyle(color: Colors.white)),
              )),
            ),
            ListenableBuilder(
              listenable: _p,
              builder: (_, __) {
                final c = _p.controls;
                if (c == null || c.maxZoom <= 1.01) {
                  return const SizedBox.shrink();
                }
                return Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: _round(TextButton(
                    onPressed: _cycleZoom,
                    child: Text(
                        '${c.zoom.toStringAsFixed(c.zoom < 10 ? 1 : 0)}x',
                        style: const TextStyle(color: Colors.white)),
                  )),
                );
              },
            ),
            const SizedBox(width: 8),
            ListenableBuilder(
              listenable: _p,
              builder: (_, __) => _p.controls == null
                  ? const SizedBox.shrink()
                  : _round(IconButton(
                      tooltip: '손전등',
                      onPressed: _toggleTorch,
                      icon: Icon(
                          _p.controls!.torchOn
                              ? Icons.flashlight_on
                              : Icons.flashlight_off,
                          color: _p.controls!.torchOn
                              ? Colors.amberAccent
                              : Colors.white),
                    )),
            ),
          ],
        ),
      );

  Widget? _panelFooter(AiState s) {
    // AI가 실패해도(인터넷 없음 등) 찍은 사진이 있으면 사진만 저장 → 나중에 분석
    if (s.error != null && s.jpeg != null) {
      final saved = _saved.containsKey(s);
      return Padding(
        padding: const EdgeInsets.only(top: 8, right: 8),
        child: Align(
          alignment: Alignment.centerRight,
          child: saved
              ? const Text('저장됨 · 기록 화면에서 나중에 AI 분석',
                  style: TextStyle(color: Colors.greenAccent))
              : FilledButton.icon(
                  onPressed: _saving ? null : () => _saveFailedShot(s),
                  icon: const Icon(Icons.save_alt),
                  label: const Text('사진만 저장 · 나중에 AI 분석'),
                ),
        ),
      );
    }
    if (s.report == null || s.jpeg == null) return null;
    final saved = _saved.containsKey(s);
    return Padding(
      padding: const EdgeInsets.only(top: 8, right: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          if (saved)
            const Padding(
              padding: EdgeInsets.only(right: 8),
              child: Row(children: [
                Icon(Icons.check_circle, color: Colors.greenAccent, size: 18),
                SizedBox(width: 4),
                Text('저장됨', style: TextStyle(color: Colors.greenAccent)),
              ]),
            )
          else
            FilledButton.icon(
              onPressed: _saving ? null : () => _save(s, FindingSource.ai),
              icon: const Icon(Icons.save_alt),
              label: const Text('기록 저장'),
            ),
        ],
      ),
    );
  }

  Widget _bottomBar() => ListenableBuilder(
        listenable: _p,
        builder: (_, __) => Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _round(Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Switch(value: _p.autoAi, onChanged: (v) => _p.autoAi = v),
                const Padding(
                  padding: EdgeInsets.only(bottom: 6),
                  child: Text('자동',
                      style: TextStyle(color: Colors.white, fontSize: 12)),
                ),
              ],
            )),
            _round(IconButton(
              tooltip: '사진만 기록',
              iconSize: 30,
              color: Colors.white,
              disabledColor: Colors.white24,
              onPressed: _saving || _p.source == null ? null : _photoOnly,
              icon: const Icon(Icons.add_a_photo),
            )),
            ValueListenableBuilder<AiState?>(
              valueListenable: _p.ai,
              builder: (_, s, __) {
                final busy = s?.running == true;
                final enabled = !busy && _p.source != null;
                return SizedBox(
                  width: 84,
                  height: 84,
                  child: FloatingActionButton(
                    heroTag: 'ai',
                    shape: const CircleBorder(),
                    // 현장에서 한눈에 보이게 진한 노랑
                    // 카메라가 안 열렸으면 회색(눌러도 아무 일 없음을 보이게)
                    backgroundColor:
                        enabled || busy ? Colors.amber : Colors.grey.shade800,
                    foregroundColor:
                        enabled || busy ? Colors.black : Colors.white38,
                    onPressed: enabled ? _p.runAi : null,
                    child: busy
                        ? const CircularProgressIndicator()
                        : const Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.health_and_safety, size: 34),
                              Text('AI 점검', style: TextStyle(fontSize: 11)),
                            ],
                          ),
                  ),
                );
              },
            ),
            _round(IconButton(
              tooltip: '점검 종료',
              iconSize: 30,
              onPressed: _finish,
              icon: const Icon(Icons.stop_circle, color: Colors.redAccent),
            )),
          ],
        ),
      );

  Widget _round(Widget child) => DecoratedBox(
        decoration: BoxDecoration(
            color: Colors.black54, borderRadius: BorderRadius.circular(12)),
        child: child,
      );
}
