import 'dart:async';
import 'package:flutter/material.dart';
import '../camera/camera_pipeline.dart';
import '../camera/camera_recorder.dart';
import '../sources/recording_frame_source.dart';

/// 카메라 화면 왼쪽의 시험용 녹화 버튼(설정 → 개발자 → 녹화 버튼 보이기).
/// 누르면 카메라 원본 + 자이로 녹화 시작, 다시 누르면 멈추고 요약을 알림. 녹화 중에는 빨간 점과 시간.
class RecordButton extends StatefulWidget {
  const RecordButton({super.key, required this.pipeline});
  final CameraPipeline pipeline;

  @override
  State<RecordButton> createState() => _RecordButtonState();
}

class _RecordButtonState extends State<RecordButton> {
  Timer? _tick;
  CameraRecorder? _was;

  CameraPipeline get p => widget.pipeline;

  @override
  void initState() {
    super.initState();
    p.recording.addListener(_onRecording);
  }

  @override
  void dispose() {
    p.recording.removeListener(_onRecording);
    _tick?.cancel();
    super.dispose();
  }

  /// 시작하면 1초마다 시간 갱신, 끝나면(버튼이든 10분 자동이든) 요약 알림
  void _onRecording() {
    final r = p.recording.value;
    _tick?.cancel();
    if (r != null) {
      _tick = Timer.periodic(
          const Duration(seconds: 1), (_) => mounted ? setState(() {}) : null);
    } else if (_was != null && mounted) {
      final done = p.lastRecording ?? _was!;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('녹화 저장: ${clock(done.seconds)} · ${done.frames}장'
            '${done.dropped > 0 ? '(건너뜀 ${done.dropped})' : ''}'
            ' · ${(done.bytes / 1e6).toStringAsFixed(0)}MB'),
      ));
    }
    _was = r;
    if (mounted) setState(() {});
  }

  static String clock(double s) =>
      '${s ~/ 60}:${(s % 60).floor().toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([p, p.settings]),
      builder: (context, _) {
        final r = p.recording.value;
        // 카메라 대신 녹화가 돌고 있으면 헷갈리지 않게 표시만(누를 수 없음)
        if (p.source is RecordingFrameSource) {
          return const Chip(
            avatar: Icon(Icons.play_arrow, size: 18),
            label: Text('녹화 재생'),
            visualDensity: VisualDensity.compact,
          );
        }
        if (r == null &&
            (!p.settings.recordButton ||
                p.kind == SourceKind.images ||
                p.source == null)) {
          return const SizedBox.shrink();
        }
        return Material(
          color: r != null ? Colors.red.shade700 : Colors.black54,
          shape: const StadiumBorder(),
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: () => r != null ? p.stopRecording() : p.startRecording(),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(r != null ? Icons.stop : Icons.fiber_manual_record,
                      color: r != null ? Colors.white : Colors.redAccent,
                      size: 18),
                  const SizedBox(width: 6),
                  Text(r != null ? clock(r.seconds) : '녹화',
                      style: const TextStyle(
                          color: Colors.white, fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 녹화 고르기. 고른 녹화 폴더 경로, [allowOff]면 "카메라로 되돌리기"는 '', 취소는 null
Future<String?> pickRecording(BuildContext context,
    {bool allowOff = false}) async {
  final root = await Recording.root();
  final list = root == null ? const <Recording>[] : await Recording.list(root);
  if (!context.mounted) return null;
  return showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          const ListTile(
            title:
                Text('녹화 고르기', style: TextStyle(fontWeight: FontWeight.bold)),
            subtitle: Text('카메라 화면의 녹화 버튼으로 찍은 것(설정 → 개발자 → 녹화 버튼 보이기)'),
          ),
          if (allowOff)
            ListTile(
              leading: const Icon(Icons.videocam),
              title: const Text('카메라 쓰기(녹화 재생 끄기)'),
              onTap: () => Navigator.pop(context, ''),
            ),
          if (list.isEmpty)
            const ListTile(
              leading: Icon(Icons.info_outline),
              title: Text('녹화가 없습니다'),
            ),
          for (final r in list)
            ListTile(
              leading: const Icon(Icons.movie),
              title: Text(recordingTitle(r.name)),
              subtitle:
                  Text('${_RecordButtonState.clock(r.seconds)} · ${r.frames}장'),
              onTap: () => Navigator.pop(context, r.dir.path),
            ),
        ],
      ),
    ),
  );
}

/// 폴더 이름(2026-11-04T101530) → "11/04 10:15:30"
String recordingTitle(String name) {
  final m = RegExp(r'^\d{4}-(\d\d)-(\d\d)T(\d\d)(\d\d)(\d\d)').firstMatch(name);
  return m == null ? name : '${m[1]}/${m[2]} ${m[3]}:${m[4]}:${m[5]}';
}
