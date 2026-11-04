import 'dart:io';
import 'dart:ui';
import 'package:facility_camera/analysis/hazard.dart';
import 'package:facility_camera/data/app_settings.dart';
import 'package:facility_camera/data/inspection_repository.dart';
import 'package:facility_camera/data/models.dart';
import 'package:facility_camera/data/reanalyze.dart';
import 'package:facility_camera/data/report_text.dart';
import 'package:facility_camera/analysis/hazard_analyzer.dart';
import 'dart:typed_data';
import 'package:camera/camera.dart' show ResolutionPreset;
import 'package:flutter_test/flutter_test.dart';

HazardReport _report() => HazardReport.fromJson({
      'summary': '배관 누수',
      'hazards': [
        {
          'type': '누수',
          'description': '바닥에 물',
          'severity': 'medium',
          'action': '닦기',
          'box_2d': [800, 300, 880, 650],
        },
        {
          'type': '분전반 열림',
          'description': '문 열림',
          'severity': 'high',
          'action': '닫기',
        },
      ],
    }, 2500, const Size(768, 1024));

class _StubAi implements HazardAnalyzer {
  _StubAi({this.reason});
  final String? reason;
  @override
  String? get unavailableReason => reason;
  @override
  String get description => 'stub';
  @override
  Future<HazardReport> analyze(Uint8List jpeg,
          {String? place, bool equipment = false}) async =>
      HazardReport.fromJson(
          {'summary': '나중에 분석함', 'hazards': []}, 5, const Size(1080, 1440));
}

void main() {
  late Directory tmp;
  final jpeg = File('assets/test_frames/scene_01.jpg').readAsBytesSync();

  setUp(() => tmp = Directory.systemTemp.createTempSync('fc_repo_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('점검 만들기 → 발견 저장 → 다시 읽어도 그대로(사진·박스·상태·메모)', () async {
    final repo = InspectionRepository(tmp);
    final i = await repo.create('  B2 기계실 ');
    final f = await repo.addFinding(i, jpeg, _report(), FindingSource.ai);
    await repo.updateFinding(i, f, resolved: true, memo: '배관 교체 요청');
    await repo.finish(i);
    expect(repo.photoFile(i, f).existsSync(), isTrue);

    final again = InspectionRepository(tmp);
    await again.load();
    final i2 = again.inspections.single;
    expect(i2.location, 'B2 기계실');
    expect(i2.inProgress, isFalse);
    final f2 = i2.findings.single;
    expect(f2.resolved, isTrue);
    expect(f2.memo, '배관 교체 요청');
    expect(f2.source, FindingSource.ai);
    expect(f2.imageSize, const Size(768, 1024));
    expect(f2.report.elapsedMs, 2500);
    // 심각도 순 정렬과 박스(0..1)가 그대로 복원
    expect(f2.report.hazards.map((h) => h.severity),
        [Severity.high, Severity.medium]);
    expect(f2.report.hazards[1].box!.left, closeTo(0.3, 1e-9));
    expect(f2.report.hazards[0].box, isNull);
  });

  test('수동 기록은 크기를 사진에서 읽음, 미조치 집계', () async {
    final repo = InspectionRepository(tmp);
    final i = await repo.create('3층 전기실');
    final manual = await repo.addFinding(
        i,
        jpeg,
        const HazardReport(
            summary: '직접 기록', hazards: [], elapsedMs: 0, imageSize: Size.zero),
        FindingSource.manual);
    expect(manual.imageSize, const Size(1080, 1440));
    await repo.addFinding(i, jpeg, _report(), FindingSource.auto);
    expect(i.openCount, 1); // 위험 없는 수동 기록은 미조치로 안 셈
    expect(i.openBySeverity[Severity.high], 1);
    expect(i.openBySeverity[Severity.medium], 1);
  });

  test('삭제하면 폴더째 사라지고 목록에서 빠짐, 깨진 기록은 건너뜀', () async {
    final repo = InspectionRepository(tmp);
    final a = await repo.create('A');
    await repo.create('B');
    final f = await repo.addFinding(a, jpeg, _report(), FindingSource.ai);
    final photo = repo.photoFile(a, f);
    await repo.deleteFinding(a, f);
    expect(photo.existsSync(), isFalse);
    await repo.delete(a);
    expect(repo.inspections.map((i) => i.location), ['B']);

    Directory('${tmp.path}/inspections/broken').createSync();
    File('${tmp.path}/inspections/broken/inspection.json')
        .writeAsStringSync('{깨진 json');
    final again = InspectionRepository(tmp);
    await again.load();
    expect(again.inspections.map((i) => i.location), ['B']);
  });

  test('사진만 남긴 기록을 나중에 AI 분석 → 결과 저장, 실패하면 멈추고 알림', () async {
    final repo = InspectionRepository(tmp);
    final i = await repo.create('지하 3층 기계실');
    const manual = HazardReport(
        summary: Finding.manualSummary,
        hazards: [],
        elapsedMs: 0,
        imageSize: Size.zero);
    await repo.addFinding(i, jpeg, manual, FindingSource.manual);
    await repo.addFinding(i, jpeg, manual, FindingSource.manual);
    await repo.addFinding(i, jpeg, _report(), FindingSource.ai);
    expect(i.findings.where((f) => f.needsAi).length, 2);

    // 키가 없으면 아무것도 바꾸지 않고 이유를 알림
    await expectLater(
        analyzePending(repo, _StubAi(reason: '키 없음'), i), throwsStateError);
    expect(i.findings.where((f) => f.needsAi).length, 2);

    final progress = <String>[];
    final n = await analyzePending(repo, _StubAi(), i,
        onProgress: (d, t) => progress.add('$d/$t'));
    expect(n, 2);
    expect(progress, ['0/2', '1/2', '2/2']);
    expect(i.findings.where((f) => f.needsAi), isEmpty);

    final again = InspectionRepository(tmp);
    await again.load();
    final f = again.inspections.single.findings.first;
    expect(f.report.summary, '나중에 분석함');
    expect(f.source, FindingSource.manual); // 출처는 그대로 남김
  });

  test('요약 텍스트에 장소·미조치·위험요소·메모가 들어감', () async {
    final repo = InspectionRepository(tmp);
    final i = await repo.create('B2 기계실');
    final f = await repo.addFinding(i, jpeg, _report(), FindingSource.ai);
    await repo.updateFinding(i, f, memo: '담당 김기사');
    final t = inspectionReportText(i);
    expect(t, contains('[시설 안전점검] B2 기계실'));
    expect(t, contains('미조치 위험요소: 위험 1, 주의 1'));
    expect(t, contains('[위험] 분전반 열림'));
    expect(t, contains('메모: 담당 김기사'));
  });

  test('설정 저장·불러오기, 깨진 설정 파일이면 기본값', () async {
    final file = File('${tmp.path}/settings.json');
    final s = AppSettings(file);
    await s.update((s) {
      s.preset = ResolutionPreset.medium;
      s.cameraFps = 10;
      s.gyro = false;
      s.autoAiCooldownSec = 30;
      s.idlePauseMin = 2;
      s.autoExposure = false;
      s.handControl = false;
    });
    final s2 = AppSettings(file);
    await s2.load();
    expect(s2.preset, ResolutionPreset.medium);
    expect(s2.cameraFps, 10);
    expect(s2.gyro, isFalse);
    expect(s2.autoAiCooldownSec, 30);
    expect(s2.idlePauseMin, 2);
    expect(s2.autoExposure, isFalse);
    expect(s2.handControl, isFalse);

    file.writeAsStringSync('not json');
    final s3 = AppSettings(file);
    await s3.load();
    expect(s3.preset, ResolutionPreset.high);
  });

  test('위험별 무시·완료: 조치 후 사진 저장, 다시 읽어도 유지, 되돌리면 사진 삭제', () async {
    final repo = InspectionRepository(tmp);
    final i = await repo.create('B2 기계실');
    final f = await repo.addFinding(i, jpeg, _report(), FindingSource.ai);
    // 심각도 순 정렬: 0 = 분전반 열림(high), 1 = 누수(medium)
    await repo.setHazardStatus(i, f, 1, HazardStatus.resolved,
        by: 'tap', afterJpeg: jpeg);
    await repo.setHazardStatus(i, f, 0, HazardStatus.ignored, by: 'tap');
    final after = repo.afterPhotoFile(i, f.report.hazards[1])!;
    expect(after.existsSync(), isTrue);
    expect(f.done, isTrue); // 하나는 완료, 하나는 무시 → 남은 위험 없음
    expect(i.openCount, 0);

    final repo2 = InspectionRepository(tmp);
    await repo2.load();
    final h = repo2.inspections.single.findings.single.report.hazards;
    expect(h[1].status, HazardStatus.resolved);
    expect(h[1].statusBy, 'tap');
    expect(h[1].statusAt, isNotNull);
    expect(h[1].afterPhoto, after.uri.pathSegments.last);
    expect(h[0].status, HazardStatus.ignored);
    expect(h[0].afterPhoto, isNull);

    // 되돌리기 → 미조치, 조치 후 사진 지움
    await repo.setHazardStatus(i, f, 1, HazardStatus.open, by: 'tap');
    expect(f.report.hazards[1].status, HazardStatus.open);
    expect(f.report.hazards[1].statusAt, isNull);
    expect(after.existsSync(), isFalse);
    expect(i.openCount, 1);
    expect(i.openBySeverity[Severity.medium], 1);
    expect(i.openBySeverity[Severity.high], 0); // 무시한 위험은 미조치로 안 셈
  });

  test('기록 전체 "조치 완료"를 끄면 위험별 완료도 되돌림(무시는 유지), 기록 삭제 시 조치 후 사진도 삭제', () async {
    final repo = InspectionRepository(tmp);
    final i = await repo.create('전기실');
    final f = await repo.addFinding(i, jpeg, _report(), FindingSource.ai);
    await repo.setHazardStatus(i, f, 0, HazardStatus.ignored, by: 'list');
    await repo.setHazardStatus(i, f, 1, HazardStatus.resolved,
        by: 'tap', afterJpeg: jpeg);
    final after = repo.afterPhotoFile(i, f.report.hazards[1])!;
    await repo.updateFinding(i, f, resolved: true);
    expect(f.done, isTrue);
    await repo.updateFinding(i, f, resolved: false);
    expect(f.report.hazards[1].status, HazardStatus.open);
    expect(f.report.hazards[0].status, HazardStatus.ignored);
    expect(f.done, isFalse);
    expect(after.existsSync(), isFalse);

    await repo.setHazardStatus(i, f, 1, HazardStatus.resolved,
        by: 'tap', afterJpeg: jpeg);
    final after2 = repo.afterPhotoFile(i, f.report.hazards[1])!;
    expect(after2.existsSync(), isTrue);
    await repo.deleteFinding(i, f);
    expect(after2.existsSync(), isFalse);
  });
}
