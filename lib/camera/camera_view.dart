import 'dart:async';
import 'package:flutter/material.dart';
import '../analysis/hazard.dart';
import '../core/frame.dart';
import '../hands/hand_pointer.dart';
import '../ui/box_painter.dart';
import '../ui/recording_controls.dart';
import 'camera_pipeline.dart';

/// 카메라 미리보기 + 실시간 탐지 박스 + AI 위험 박스.
/// 탭하면 그 지점에 초점·노출, 두 손가락으로 벌리면 줌.
/// [onHazardAction]을 주면 위험 박스 옆에 [무시] [완료] 버튼을 띄움:
/// 화면 탭(AR 0단계) 또는 카메라에 비친 검지 끝을 박스·버튼 위에 머무르기(AR 1단계, [HandPointer])
class CameraView extends StatefulWidget {
  const CameraView(
      {super.key,
      required this.pipeline,
      this.showDetections = true,
      this.onHazardAction});
  final CameraPipeline pipeline;
  final bool showDetections;

  /// (위험 번호, 바꿀 상태: resolved 또는 ignored, 어떻게: 'tap' 화면 탭 / 'hand' 손가락)
  final void Function(int index, HazardStatus action, String by)?
      onHazardAction;

  @override
  State<CameraView> createState() => _CameraViewState();
}

class _CameraViewState extends State<CameraView> {
  Offset? _focus; // 초점 표시 위치(화면 좌표)
  Timer? _focusTimer;
  double _zoomAtStart = 1;

  /// 버튼을 띄운 위험과 그 위험이 속한 결과(결과가 바뀌면 선택 해제)
  int? _selected;
  HazardReport? _selectedOf;

  /// 화면 속 손가락 포인터와 마지막 화면 크기(손 결과는 그리기와 따로 와서 크기를 기억해 둠)
  final _pointer = HandPointer();
  Size _view = Size.zero;

  CameraPipeline get p => widget.pipeline;

  @override
  void initState() {
    super.initState();
    p.hand.addListener(_onHand);
  }

  @override
  void didUpdateWidget(CameraView old) {
    super.didUpdateWidget(old);
    if (old.pipeline != widget.pipeline) {
      old.pipeline.hand.removeListener(_onHand);
      widget.pipeline.hand.addListener(_onHand);
    }
  }

  @override
  void dispose() {
    p.hand.removeListener(_onHand);
    _focusTimer?.cancel();
    super.dispose();
  }

  /// 손 인식 결과가 올 때마다: 검지 끝이 위험 박스에 머무르면 버튼 띄우기, 버튼에 머무르면 누르기
  void _onHand() {
    final hf = p.hand.value;
    final r = p.ai.value?.report;
    if (hf == null ||
        r == null ||
        widget.onHazardAction == null ||
        _view.isEmpty) {
      if (_pointer.tip != null) setState(_pointer.reset);
      return;
    }
    final rects = HazardBoxPainter.viewRects(r, _view,
        shift: p.hazardShift.value, anchored: p.hazardAnchored.value)
      ..removeWhere((i, _) => r.hazards[i].status != HazardStatus.open);
    final sel = _liveSelection(r);
    final selRect = sel == null ? null : rects[sel];
    final ev = _pointer.update(hf.ms, hf.pointer?.tip, _view,
        hazards: rects,
        selected: selRect == null ? null : sel,
        layout: selRect == null ? null : HazardActionLayout.of(selRect, _view),
        moving: p.movingFast);
    setState(() {
      switch (ev) {
        case SelectHazard(:final index):
          _selected = index;
          _selectedOf = r;
        case PressAction(:final action):
          if (sel != null) _act(sel, action, 'hand');
        case null:
          break;
      }
    });
  }

  void _act(int i, HazardStatus s, String by) {
    _selected = null;
    widget.onHazardAction?.call(i, s, by);
  }

  /// 지금 결과에서 아직 유효한 선택(처리됐거나 결과가 바뀌면 null)
  int? _liveSelection(HazardReport? r) {
    final i = _selected;
    if (i == null || r == null || !identical(r, _selectedOf)) return null;
    if (i >= r.hazards.length || r.hazards[i].status != HazardStatus.open) {
      return null;
    }
    return i;
  }

  Future<void> _onTap(TapUpDetails d, Size size) async {
    // 위험 박스를 누르면 무시·완료 버튼, 다른 곳을 누르면 선택 해제 + 초점
    final r = p.ai.value?.report;
    if (widget.onHazardAction != null && r != null) {
      final hit = HazardBoxPainter.hazardAt(r, size, d.localPosition,
          shift: p.hazardShift.value, anchored: p.hazardAnchored.value);
      if (hit != null) {
        setState(() {
          _selected = hit;
          _selectedOf = r;
        });
        return;
      }
      if (_selected != null) setState(() => _selected = null);
    }
    if (p.controls == null) return;
    setState(() => _focus = d.localPosition);
    _focusTimer?.cancel();
    _focusTimer = Timer(const Duration(milliseconds: 900),
        () => mounted ? setState(() => _focus = null) : null);
    try {
      await p.focusAt(Offset(
          d.localPosition.dx / size.width, d.localPosition.dy / size.height));
    } catch (_) {
      // 고정 초점 카메라·에뮬레이터: 조용히 무시(표시만)
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: p,
      builder: (context, _) {
        final src = p.source;
        if (p.error != null) {
          return _ErrorView(message: p.error!, onRetry: () => p.open(p.kind));
        }
        if (src == null) {
          return const Center(child: CircularProgressIndicator());
        }
        final controls = p.controls;
        return Center(
          child: ValueListenableBuilder<double>(
            valueListenable: src.aspectRatio,
            builder: (_, aspect, child) =>
                AspectRatio(aspectRatio: aspect, child: child),
            child: LayoutBuilder(
              builder: (context, box) {
                _view = box.biggest; // 손 인식 결과를 화면 좌표로 바꿀 때 씀
                return GestureDetector(
                  onTapUp: (d) => _onTap(d, box.biggest),
                  onScaleStart: (_) => _zoomAtStart = controls?.zoom ?? 1,
                  onScaleUpdate: (d) {
                    if (controls == null || d.pointerCount < 2) return;
                    p.setZoom(_zoomAtStart * d.scale).catchError((_) {});
                  },
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      src.buildPreview(context),
                      if (widget.showDetections)
                        RepaintBoundary(
                          child: ValueListenableBuilder<List<Detection>>(
                            valueListenable: p.detections,
                            builder: (_, list, __) =>
                                CustomPaint(painter: DetectionPainter(list)),
                          ),
                        ),
                      ValueListenableBuilder<AiState?>(
                        valueListenable: p.ai,
                        builder: (_, s, __) => s?.report == null
                            ? const SizedBox.shrink()
                            // 찍은 뒤 폰이 움직인 만큼 옮겨 위험 표시를 제자리에
                            : ListenableBuilder(
                                listenable: Listenable.merge([
                                  p.hazardShift,
                                  p.hazardAnchored,
                                  p.hazardRevision
                                ]),
                                builder: (_, __) {
                                  final r = s!.report!;
                                  final sel = _liveSelection(r);
                                  return Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      CustomPaint(
                                          painter: HazardBoxPainter(r,
                                              shift: p.hazardShift.value,
                                              anchored: p.hazardAnchored.value,
                                              selected: sel,
                                              revision:
                                                  p.hazardRevision.value)),
                                      if (sel != null)
                                        ..._actionsFor(r, sel, box.biggest),
                                    ],
                                  );
                                },
                              ),
                      ),
                      // 화면 속 검지 끝 커서 + 머무르기 진행 원
                      if (_pointer.tip != null)
                        IgnorePointer(
                          child: CustomPaint(
                              painter: _HandCursorPainter(_pointer.tip!,
                                  _pointer.target, _pointer.progress)),
                        ),
                      if (_focus != null)
                        Positioned(
                          left: _focus!.dx - 32,
                          top: _focus!.dy - 32,
                          child: IgnorePointer(
                            child: Container(
                              width: 64,
                              height: 64,
                              decoration: BoxDecoration(
                                  border: Border.all(
                                      color: Colors.amberAccent, width: 2),
                                  borderRadius: BorderRadius.circular(8)),
                            ),
                          ),
                        ),
                      if (controls != null && controls.zoom > 1.01)
                        Positioned(
                          bottom: 8,
                          left: 0,
                          right: 0,
                          child: Center(
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                  color: Colors.black54,
                                  borderRadius: BorderRadius.circular(10)),
                              child: Text(
                                  '${controls.zoom.toStringAsFixed(1)}x',
                                  style: const TextStyle(color: Colors.white)),
                            ),
                          ),
                        ),
                      // 시험용 녹화(위·아래·오른쪽은 점검 화면 버튼이 있어 왼쪽 가운데)
                      Align(
                        alignment: const Alignment(-1, -0.2),
                        child: Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: RecordButton(pipeline: p),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }

  /// 선택한 위험 박스 옆의 [무시] [완료](자리는 [HazardActionLayout], 손가락 판정과 같음)
  List<Widget> _actionsFor(HazardReport r, int i, Size view) {
    final rect = HazardBoxPainter.viewRects(r, view,
        shift: p.hazardShift.value, anchored: p.hazardAnchored.value)[i];
    if (rect == null) return const [];
    final l = HazardActionLayout.of(rect, view);
    void act(HazardStatus s) => setState(() => _act(i, s, 'tap'));
    Widget button(Rect at, HazardStatus s) {
      final done = s == HazardStatus.resolved;
      return Positioned.fromRect(
        rect: at,
        child: FilledButton.icon(
          style: FilledButton.styleFrom(
              backgroundColor:
                  done ? HazardBoxPainter.resolvedColor : Colors.grey.shade800,
              foregroundColor: done ? Colors.black : Colors.white,
              minimumSize: Size.fromHeight(at.height)),
          onPressed: () => act(s),
          icon: Icon(done ? Icons.check : Icons.visibility_off),
          label: Text(done ? '완료' : '무시',
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: done ? FontWeight.bold : FontWeight.normal)),
        ),
      );
    }

    return [
      button(l.ignore, HazardStatus.ignored),
      button(l.done, HazardStatus.resolved),
    ];
  }
}

/// 화면 속 검지 끝: 흰 점 + 머무르기 진행 원(박스 위 = 흰색, 버튼 위 = 그 버튼 색)
class _HandCursorPainter extends CustomPainter {
  _HandCursorPainter(this.tip, this.target, this.progress);
  final Offset tip;
  final HandTarget target;
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawCircle(tip, 9, Paint()..color = Colors.white);
    canvas.drawCircle(
        tip,
        9,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = Colors.black);
    if (target == HandTarget.none) return;
    final color = switch (target) {
      HandTarget.done => HazardBoxPainter.resolvedColor,
      HandTarget.ignore => Colors.grey,
      _ => Colors.white,
    };
    final ring = Rect.fromCircle(center: tip, radius: 24);
    canvas.drawCircle(
        tip,
        24,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 5
          ..color = Colors.black38);
    canvas.drawArc(
        ring,
        -1.5708,
        6.2832 * progress,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 5
          ..strokeCap = StrokeCap.round
          ..color = color);
  }

  @override
  bool shouldRepaint(_HandCursorPainter old) =>
      old.tip != tip || old.target != target || old.progress != progress;
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.videocam_off, color: Colors.white54, size: 48),
              const SizedBox(height: 12),
              Text(message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white)),
              const SizedBox(height: 16),
              FilledButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh),
                  label: const Text('다시 시도')),
            ],
          ),
        ),
      );
}
