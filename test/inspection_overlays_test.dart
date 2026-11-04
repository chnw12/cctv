import 'package:facility_camera/ui/inspection_overlays.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('사용법 카드: 볼륨 키 안내가 있고 "알겠어요"로 닫힘', (t) async {
    var closed = 0;
    await t.pumpWidget(MaterialApp(
        home: Scaffold(body: CameraTipsCard(onClose: () => closed++))));
    expect(find.text('볼륨 키  '), findsOneWidget);
    await t.tap(find.text('알겠어요'));
    expect(closed, 1);
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
