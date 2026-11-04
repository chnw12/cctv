import '../analysis/hazard_analyzer.dart';
import 'inspection_repository.dart';
import 'models.dart';

/// 사진만 남긴 기록을 AI로 분석해 결과를 채움(지하 기계실 등 인터넷이 없던 곳의 기록).
/// 하나라도 실패하면 거기서 멈추고 예외를 던짐(이미 분석한 것은 저장된 채로).
Future<void> analyzeFinding(InspectionRepository repo, HazardAnalyzer ai,
    Inspection i, Finding f) async {
  final reason = ai.unavailableReason;
  if (reason != null) throw StateError(reason);
  final jpeg = await repo.photoFile(i, f).readAsBytes();
  final report = await ai.analyze(jpeg, place: i.location);
  await repo.setReport(i, f, report);
}

/// 점검 안의 미분석 기록을 차례로 분석. 진행 상황을 (끝난 수, 전체 수)로 알림
Future<int> analyzePending(
    InspectionRepository repo, HazardAnalyzer ai, Inspection i,
    {void Function(int done, int total)? onProgress}) async {
  final pending = i.findings.where((f) => f.needsAi).toList();
  var done = 0;
  onProgress?.call(0, pending.length);
  for (final f in pending) {
    await analyzeFinding(repo, ai, i, f);
    onProgress?.call(++done, pending.length);
  }
  return done;
}
