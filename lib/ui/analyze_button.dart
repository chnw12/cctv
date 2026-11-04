import 'package:flutter/material.dart';
import '../app/app.dart';
import '../data/models.dart';
import '../data/reanalyze.dart';

/// 사진만 남긴 기록을 AI로 분석하는 버튼. findings가 한 개면 그것만, 여러 개면 차례로
class AnalyzeButton extends StatefulWidget {
  const AnalyzeButton(this.inspection, {super.key, this.finding});
  final Inspection inspection;

  /// null이면 점검 안의 미분석 기록 전부
  final Finding? finding;

  @override
  State<AnalyzeButton> createState() => _AnalyzeButtonState();
}

class _AnalyzeButtonState extends State<AnalyzeButton> {
  String? _progress;

  Future<void> _run() async {
    final scope = AppScope.of(context);
    setState(() => _progress = '분석 중…');
    try {
      final f = widget.finding;
      if (f != null) {
        await analyzeFinding(scope.repo, scope.analyzer, widget.inspection, f);
      } else {
        await analyzePending(scope.repo, scope.analyzer, widget.inspection,
            onProgress: (d, t) {
          if (mounted) setState(() => _progress = '분석 중… $d/$t');
        });
      }
    } catch (e) {
      debugPrint('미분석 사진 AI 분석 실패: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('AI 분석 실패: ${e is StateError ? e.message : e}')));
      }
    } finally {
      if (mounted) setState(() => _progress = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.finding != null
        ? 1
        : widget.inspection.findings.where((f) => f.needsAi).length;
    if (n == 0) return const SizedBox.shrink();
    final busy = _progress != null;
    return FilledButton.tonalIcon(
      onPressed: busy ? null : _run,
      icon: busy
          ? const SizedBox.square(
              dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.auto_awesome),
      label: Text(busy
          ? _progress!
          : widget.finding != null
              ? 'AI로 분석'
              : '미분석 사진 $n장 AI 분석'),
    );
  }
}
