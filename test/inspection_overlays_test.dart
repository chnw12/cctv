import 'package:facility_camera/analysis/hazard.dart';
import 'package:facility_camera/ui/hazard_panel.dart';
import 'package:facility_camera/ui/inspection_overlays.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('사용법 카드: 볼륨 키 안내가 있고 "알겠어요"로 닫힘', (t) async {
    var closed = 0;
    await t.pumpWidget(MaterialApp(
        home: Scaffold(body: CameraTipsCard(onClose: () => closed++))));
    expect(find.text('볼륨 키  '), findsOneWidget);
    expect(find.text('멈춰 서서  '), findsOneWidget); // 걸으면서 화면 보지 않기
    await t.tap(find.text('알겠어요'));
    expect(closed, 1);
  });

  testWidgets('AI 결과에 위험이 없으면 "안전"이 아니라 "AI가 못 찾음"으로(초록 아님)', (t) async {
    const empty = HazardReport(
        summary: '정돈된 기계실', hazards: [], elapsedMs: 0, imageSize: Size(1, 1));
    await t.pumpWidget(
        const MaterialApp(home: Scaffold(body: HazardList(empty))));
    final text = t.widget<Text>(find.text(HazardList.noHazardText));
    expect(text.style?.color, isNot(Colors.greenAccent));
    expect(find.text('발견된 위험요소 없음'), findsNothing);

    await t.pumpWidget(const MaterialApp(
        home: Scaffold(body: HazardList(empty, emptyText: 'AI 분석 전 사진'))));
    expect(find.text('AI 분석 전 사진'), findsOneWidget);
  });

  testWidgets('일시정지 화면: 어디를 탭해도 다시 시작', (t) async {
    var resumed = 0;
    await t.pumpWidget(MaterialApp(
        home: Scaffold(body: PausedOverlay(onResume: () => resumed++))));
    expect(find.textContaining('배터리 절약'), findsOneWidget);
    await t.tapAt(const Offset(20, 20));
    expect(resumed, 1);
  });
}
