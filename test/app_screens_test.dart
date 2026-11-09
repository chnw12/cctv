import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:facility_camera/analysis/hazard.dart';
import 'package:facility_camera/analysis/hazard_analyzer.dart';
import 'package:facility_camera/app/app.dart';
import 'package:facility_camera/data/app_settings.dart';
import 'package:facility_camera/data/inspection_repository.dart';
import 'package:facility_camera/data/models.dart';
import 'package:facility_camera/screens/finding_detail_screen.dart';
import 'package:facility_camera/screens/history_screen.dart';
import 'package:facility_camera/screens/inspection_detail_screen.dart';
import 'package:facility_camera/screens/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _NoKeyAi implements HazardAnalyzer {
  @override
  String? get unavailableReason => 'GEMINI_API_KEY 없음';
  @override
  String get description => '테스트';
  @override
  Future<HazardReport> analyze(Uint8List jpeg,
          {String? place, bool equipment = false}) =>
      throw UnimplementedError();
}

HazardReport _report(String sev, [String summary = '배관 누수']) =>
    HazardReport.fromJson({
      'summary': summary,
      'hazards': [
        {'type': '누수', 'description': '바닥 물', 'severity': sev, 'action': '닦기'}
      ],
    }, 1000, const Size(768, 1024));

void main() {
  late Directory tmp;
  late InspectionRepository repo;
  late AppSettings settings;
  final jpeg = File('assets/test_frames/scene_01.jpg').readAsBytesSync();

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('fc_ui_');
    repo = InspectionRepository(tmp);
    settings = AppSettings(File('${tmp.path}/settings.json'));
  });
  tearDown(() {
    // Windows: 화면의 Image.file이 사진을 아직 열고 있으면 지우기 실패 → 임시 폴더라 무시
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException catch (_) {}
  });

  Widget app({Widget? home}) =>
      FacilityApp(settings: settings, repo: repo, analyzer: _NoKeyAi())
          .withHome(home);

  testWidgets('첫 화면: 기록 없음 안내 + AI 사용 불가 이유 표시', (t) async {
    await t.pumpWidget(app());
    expect(find.text('새 점검 시작'), findsOneWidget);
    expect(find.textContaining('아직 점검 기록이 없습니다'), findsOneWidget);
    expect(find.text('AI 점검 사용 불가'), findsOneWidget);
    expect(find.text('GEMINI_API_KEY 없음'), findsOneWidget);
  });

  testWidgets('진행 중 점검은 위에 "이어서", 탭하면 상세(발견·미조치)', (t) async {
    await t.runAsync(() async {
      final i = await repo.create('B2 기계실');
      await repo.addFinding(i, jpeg, _report('high'), FindingSource.ai);
    });
    await t.pumpWidget(app());
    expect(find.text('진행 중: B2 기계실'), findsOneWidget);
    expect(find.text('이어서'), findsOneWidget);

    await t.tap(find.text('진행 중: B2 기계실'));
    await t.pumpAndSettle();
    expect(find.text('발견 1건 · 미조치 1건'), findsOneWidget);
    expect(find.text('이어서 점검'), findsOneWidget);
    expect(find.text('배관 누수'), findsOneWidget);
  });

  testWidgets('발견사항 상세: 조치 완료 토글·메모가 저장됨', (t) async {
    late Inspection i;
    late Finding f;
    await t.runAsync(() async {
      i = await repo.create('3층 전기실');
      f = await repo.addFinding(i, jpeg, _report('medium'), FindingSource.ai);
    });
    await t.pumpWidget(
        app(home: FindingDetailScreen(inspectionId: i.id, findingId: f.id)));
    // 사진이 화면을 다 차지해 아래 목록은 스크롤해야 만들어짐. 위험요소 줄은 Text.rich 안에 있음
    final hazardLine = find.textContaining('바닥 물', findRichText: true);
    final page = find.byType(Scrollable).first; // 메모 칸도 자체 스크롤이 있어 바깥 목록을 지정
    await t.scrollUntilVisible(hazardLine, 200, scrollable: page);
    expect(hazardLine, findsOneWidget);
    await t.scrollUntilVisible(find.byType(TextField), 200, scrollable: page);

    await t.runAsync(() async {
      await t.tap(find.byType(Switch));
      await t.pump();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    expect(f.resolved, isTrue);

    await t.enterText(find.byType(TextField), '부품 주문함');
    await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 700)));
    await t.pump(const Duration(milliseconds: 700));
    expect(f.memo, '부품 주문함');
  });

  testWidgets('발견사항 상세: 위험 하나를 완료 → 상태·되돌리기 표시, 되돌리면 다시 미조치', (t) async {
    late Inspection i;
    late Finding f;
    await t.runAsync(() async {
      i = await repo.create('3층 전기실');
      f = await repo.addFinding(i, jpeg, _report('high'), FindingSource.ai);
    });
    await t.pumpWidget(
        app(home: FindingDetailScreen(inspectionId: i.id, findingId: f.id)));
    final page = find.byType(Scrollable).first;
    final done = find.widgetWithText(TextButton, '완료');
    await t.scrollUntilVisible(done, 200, scrollable: page);
    await t.runAsync(() async {
      await t.tap(done);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await t.pump();
    final h = f.report.hazards.single;
    expect(h.status, HazardStatus.resolved);
    expect(h.statusBy, 'list');
    expect(f.done, isTrue);
    expect(i.openCount, 0);
    expect(find.textContaining('기록 화면에서'), findsOneWidget);

    await t.runAsync(() async {
      await t.tap(find.widgetWithText(TextButton, '되돌리기'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await t.pump();
    expect(h.status, HazardStatus.open);
    expect(i.openCount, 1);
    expect(find.widgetWithText(TextButton, '무시'), findsOneWidget);
  });

  testWidgets('발견사항 상세: 위험 등급 무시는 오탐 확인 창(카메라 화면과 같게), 모두 무시하면 "오탐 처리"',
      (t) async {
    late Inspection i;
    late Finding f;
    await t.runAsync(() async {
      i = await repo.create('3층 전기실');
      f = await repo.addFinding(i, jpeg, _report('high'), FindingSource.ai);
    });
    await t.pumpWidget(
        app(home: FindingDetailScreen(inspectionId: i.id, findingId: f.id)));
    final page = find.byType(Scrollable).first;
    final ignore = find.widgetWithText(TextButton, '무시');
    await t.scrollUntilVisible(ignore, 200, scrollable: page);
    final h = f.report.hazards.single;

    // 취소하면 그대로 미조치
    await t.tap(ignore);
    await t.pumpAndSettle();
    expect(find.textContaining('AI가 잘못 짚은 경우(오탐)에만'), findsOneWidget);
    await t.tap(find.text('취소'));
    await t.pumpAndSettle();
    expect(h.status, HazardStatus.open);
    expect(i.openCount, 1);

    // 확인하면 무시 → 남은 일은 없지만 "조치 완료"가 아니라 오탐 처리
    // 버튼 처리(확인 창 → 파일 저장)가 실제 시간에서 돌게 runAsync 안에서 누르고,
    // 저장소가 알릴 때까지 기다림(가짜 시간에서 시작하면 파일 쓰기가 끝나지 않음)
    late Completer<void> saved;
    void onSaved() => saved.isCompleted ? null : saved.complete();
    repo.addListener(onSaved);
    await t.runAsync(() async {
      saved = Completer<void>(); // 실제 시간 쪽에서 만들어야 완료 알림이 돎
      await t.tap(ignore);
      await t.pumpAndSettle();
      await t.tap(find.widgetWithText(FilledButton, '무시'));
      await t.pump();
      await saved.future.timeout(const Duration(seconds: 5));
    });
    repo.removeListener(onSaved);
    await t.pumpAndSettle();
    expect(h.status, HazardStatus.ignored);
    expect(h.statusBy, 'list');
    expect(i.openCount, 0);
    expect([f.allIgnored, f.finished], [true, false]);
    await t.scrollUntilVisible(find.byType(SwitchListTile), 200,
        scrollable: page);
    expect(find.text('AI가 짚은 위험을 모두 오탐으로 처리함'), findsOneWidget);
    expect(t.widget<SwitchListTile>(find.byType(SwitchListTile)).value, isFalse);
  });

  testWidgets('점검 상세: 위험순으로 바꾸면 심각한 발견이 위로', (t) async {
    late Inspection i;
    await t.runAsync(() async {
      i = await repo.create('C 보일러실');
      await repo.addFinding(
          i, jpeg, _report('high', '위험한 것'), FindingSource.ai);
      await repo.addFinding(i, jpeg, _report('low', '사소한 것'), FindingSource.ai);
    });
    await t.pumpWidget(app(home: InspectionDetailScreen(inspectionId: i.id)));
    double y(String text) => t.getTopLeft(find.text(text)).dy;
    expect(y('사소한 것'), lessThan(y('위험한 것'))); // 시간순: 최신(사소한 것) 먼저
    await t.tap(find.text('위험순'));
    await t.pumpAndSettle();
    expect(y('위험한 것'), lessThan(y('사소한 것')));
  });

  testWidgets('기록 목록: "미조치 있음" 필터', (t) async {
    await t.runAsync(() async {
      final a = await repo.create('A 기계실');
      await repo.addFinding(a, jpeg, _report('high'), FindingSource.ai);
      final b = await repo.create('B 전기실');
      final f =
          await repo.addFinding(b, jpeg, _report('low'), FindingSource.ai);
      await repo.updateFinding(b, f, resolved: true);
    });
    await t.pumpWidget(app(home: const HistoryScreen()));
    expect(find.text('A 기계실'), findsOneWidget);
    expect(find.text('B 전기실'), findsOneWidget);
    await t.tap(find.text('미조치 있음'));
    await t.pumpAndSettle();
    expect(find.text('A 기계실'), findsOneWidget);
    expect(find.text('B 전기실'), findsNothing);
  });

  testWidgets('설정: 자이로 끄면 저장됨', (t) async {
    await t.pumpWidget(app(home: const SettingsScreen()));
    expect(settings.gyro, isTrue);
    await t.runAsync(() async {
      await t.tap(find.text('자이로 보정'));
      await t.pump();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    expect(settings.gyro, isFalse);
    expect(File('${tmp.path}/settings.json').readAsStringSync(),
        contains('"gyro":false'));
  });
}

extension on FacilityApp {
  /// 테스트에서 첫 화면 대신 특정 화면을 띄우기
  Widget withHome(Widget? home) => home == null
      ? this
      : AppScope(
          settings: settings,
          repo: repo,
          analyzer: analyzer,
          child: MaterialApp(home: home));
}
