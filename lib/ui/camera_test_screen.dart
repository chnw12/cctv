import 'dart:io';
import 'package:flutter/material.dart';
import '../camera/camera_pipeline.dart';
import '../camera/camera_view.dart';
import '../data/app_settings.dart';
import 'hazard_panel.dart';
import 'recording_controls.dart';

/// 개발자 도구: 카메라·탐지·추적 성능 확인(설정 화면에서 진입).
/// 왼쪽 위 숫자판을 탭하면 해상도가 바뀌고, 아래에서 폰 카메라/테스트 이미지/녹화 재생을 고릅니다.
class CameraTestScreen extends StatefulWidget {
  const CameraTestScreen({super.key, required this.settings});
  final AppSettings settings;

  @override
  State<CameraTestScreen> createState() => _CameraTestScreenState();
}

class _CameraTestScreenState extends State<CameraTestScreen> {
  late final CameraPipeline _p = CameraPipeline(settings: widget.settings)
    ..ecoEnabled = false // 처리 FPS·추론 시간을 재는 화면이라 절전으로 줄이지 않음
    ..open(SourceKind.camera);

  static const _presets = AppSettings.presetChoices;

  @override
  void dispose() {
    _p.dispose();
    super.dispose();
  }

  void _cyclePreset() {
    if (_p.kind != SourceKind.camera) return;
    final s = widget.settings;
    // 설정이 바뀌면 파이프라인이 알아서 카메라를 다시 엶
    s.update((s) => s.preset =
        _presets[(_presets.indexOf(s.preset) + 1) % _presets.length]);
  }

  /// 녹화 재생은 녹화를 고른 뒤 엶(취소하면 그대로)
  Future<void> _select(SourceKind kind) async {
    if (kind == SourceKind.recording) {
      final path = await pickRecording(context);
      if (path == null || path.isEmpty) return;
      _p.replayDir = Directory(path);
    }
    await _p.open(kind);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          CameraView(pipeline: _p),
          // 좌상단 HUD (카메라일 때 탭하면 해상도 순환)
          SafeArea(
            child: Align(
              alignment: Alignment.topLeft,
              child: GestureDetector(
                onTap: _cyclePreset,
                child: Container(
                  margin: const EdgeInsets.all(8),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(8)),
                  child: ValueListenableBuilder<Metrics>(
                    valueListenable: _p.metrics,
                    builder: (_, m, __) => Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '입력 ${m.inFps}  처리 ${m.fps} FPS   탐지 ${m.count}개   ${m.inferMs}ms',
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w600),
                        ),
                        if (_p.kind == SourceKind.camera)
                          Text(
                            '${m.frameSize.width.toInt()}x${m.frameSize.height.toInt()} '
                            '(${widget.settings.preset.name}) · 탭하면 해상도 변경',
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 11),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          // 우상단 AI 점검: 버튼 = 지금 한 번, 스위치 = 새 물체 나타나면 자동
          SafeArea(
            child: Align(
              alignment: Alignment.topRight,
              child: Container(
                margin: const EdgeInsets.all(8),
                padding: const EdgeInsets.only(left: 10),
                decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(8)),
                child: ListenableBuilder(
                  listenable: _p,
                  builder: (_, __) => Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('자동', style: TextStyle(color: Colors.white)),
                      Switch(value: _p.autoAi, onChanged: (v) => _p.autoAi = v),
                      ValueListenableBuilder<AiState?>(
                        valueListenable: _p.ai,
                        builder: (_, s, __) => IconButton(
                          tooltip: 'AI 점검',
                          onPressed: s?.running == true ? null : _p.runAi,
                          icon: s?.running == true
                              ? const SizedBox.square(
                                  dimension: 20,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.health_and_safety,
                                  color: Colors.amberAccent),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          // 하단: AI 결과 + 입력 전환
          SafeArea(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ValueListenableBuilder<AiState?>(
                      valueListenable: _p.ai,
                      builder: (_, s, __) => s == null
                          ? const SizedBox.shrink()
                          : HazardPanel(state: s, onClose: _p.clearAi),
                    ),
                    const SizedBox(height: 8),
                    ListenableBuilder(
                      listenable: _p,
                      builder: (_, __) => SegmentedButton<SourceKind>(
                        segments: const [
                          ButtonSegment(
                              value: SourceKind.camera, label: Text('폰 카메라')),
                          ButtonSegment(
                              value: SourceKind.images, label: Text('테스트 이미지')),
                          ButtonSegment(
                              value: SourceKind.recording,
                              label: Text('녹화 재생')),
                        ],
                        selected: {_p.kind},
                        onSelectionChanged: (s) => _select(s.first),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
