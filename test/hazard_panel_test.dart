import 'package:facility_camera/camera/camera_pipeline.dart';
import 'package:facility_camera/ui/hazard_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('짧은 내용이면 패널이 최대 높이까지 늘어나지 않음', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              HazardPanel(state: const AiState(error: '키 없음'), onClose: () {}),
            ],
          ),
        ),
      ),
    ));
    final h = tester.getSize(find.byType(HazardPanel)).height;
    expect(h, lessThan(100));
  });
}
