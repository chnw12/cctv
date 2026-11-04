import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:facility_camera/analysis/gemini_hazard_analyzer.dart';
import 'package:facility_camera/analysis/hazard.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// 실제 Gemini API 확인용(키가 있을 때만 실행, 평소 `flutter test`에서는 건너뜀).
///   flutter test test/gemini_live_test.dart --dart-define-from-file=secrets.json -r expanded
/// - 키·모델이 유효한지(모델 목록에서 확인)
/// - assets/test_frames/ 사진마다 응답 시간·위험요소·box_2d를 출력하고
///   박스를 그린 그림을 build/gemini_live/ 에 저장(위치가 맞는지 눈으로 확인)
/// 모델·생각 정도 비교: --dart-define=LIVE_MODELS=a,b,c --dart-define=LIVE_THINKING=,low
///   (LIVE_THINKING의 빈 값 = 모델 기본값). 비우면 secrets.json의 GEMINI_MODEL/GEMINI_THINKING 하나만.
/// 설비 위치(탐지기 학습 데이터)도 받기: --dart-define=LIVE_EQUIPMENT=true (그림에 하늘색 박스)
/// 키는 헤더로만 보내고 어디에도 출력하지 않습니다.
const _key = String.fromEnvironment('GEMINI_API_KEY');
const _liveEquipment = bool.fromEnvironment('LIVE_EQUIPMENT');
const _model = String.fromEnvironment('GEMINI_MODEL',
    defaultValue: 'gemini-3-flash-preview');
const _liveModels = String.fromEnvironment('LIVE_MODELS');
const _liveThinking = String.fromEnvironment('LIVE_THINKING',
    defaultValue: String.fromEnvironment('GEMINI_THINKING'));

void main() {
  final skip = _key.isEmpty ? 'GEMINI_API_KEY 없음 (secrets.json으로 실행)' : null;
  final models = _liveModels.isEmpty ? [_model] : _liveModels.split(',');
  final thinkings = _liveThinking.split(',');
  final rows = <String>[];

  test('키·모델 유효성: 모델 목록에 설정한 모델이 있는지', () async {
    final res = await http.get(
        Uri.parse(
            'https://generativelanguage.googleapis.com/v1beta/models?pageSize=200'),
        headers: {'x-goog-api-key': _key});
    expect(res.statusCode, 200, reason: '키 확인 실패: ${res.body}');
    final names = [
      for (final m in (jsonDecode(res.body)['models'] as List))
        if ((m['supportedGenerationMethods'] as List)
            .contains('generateContent'))
          (m['name'] as String).replaceFirst('models/', '')
    ];
    // ignore: avoid_print
    print(
        '사용 가능한 flash 계열: ${names.where((n) => n.contains('flash')).join(', ')}');
    for (final m in models) {
      expect(names, contains(m), reason: '모델 $m 이 목록에 없음');
    }
  }, skip: skip);

  final frames = Directory('assets/test_frames')
      .listSync()
      .whereType<File>()
      .where(
          (f) => RegExp(r'\.(jpe?g)$', caseSensitive: false).hasMatch(f.path))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  for (final model in models) {
    for (final thinking in thinkings) {
      final tag = '$model${thinking.isEmpty ? '' : '+$thinking'}'
          '${_liveEquipment ? '+equipment' : ''}';
      for (final f in frames) {
        final name = f.uri.pathSegments.last;
        test('실제 분석: $tag · $name', () async {
          final jpeg = f.readAsBytesSync();
          final r = await GeminiHazardAnalyzer(
                  apiKey: _key, model: model, thinking: thinking)
              .analyze(jpeg, equipment: _liveEquipment);
          // ignore: avoid_print
          print('[$tag · $name] ${r.elapsedMs}ms · ${r.summary}\n${[
            for (final h in r.hazards)
              '  - ${h.severity.name} ${h.type}: ${h.description} → ${h.action}'
                  ' box=${h.box == null ? '없음' : [
                      h.box!.left,
                      h.box!.top,
                      h.box!.right,
                      h.box!.bottom
                    ].map((v) => v.toStringAsFixed(2)).join(',')}'
          ].join('\n')}');
          if (r.equipment.isNotEmpty) {
            // ignore: avoid_print
            print('  설비: ${r.equipment.map((e) => e.name).join(', ')}');
          }
          rows.add('$tag | $name | ${r.elapsedMs}ms | 위험 ${r.hazards.length}개 '
              '(박스 ${r.hazards.where((h) => h.box != null).length})'
              '${_liveEquipment ? ' | 설비 ${r.equipment.length}개' : ''}');
          expect(r.summary, isNotEmpty);
          await _saveAnnotated(jpeg, r, 'build/gemini_live/$tag/$name.png');
        }, skip: skip, timeout: const Timeout(Duration(seconds: 90)));
      }
    }
  }

  tearDownAll(() {
    // ignore: avoid_print
    if (rows.isNotEmpty) print('\n=== 요약 ===\n${rows.join('\n')}');
  });
}

/// 원본 위에 위험 박스를 그려 PNG로 저장
Future<void> _saveAnnotated(List<int> jpeg, HazardReport r, String path) async {
  final codec = await ui.instantiateImageCodec(Uint8List.fromList(jpeg));
  final img = (await codec.getNextFrame()).image;
  final w = img.width.toDouble(), h = img.height.toDouble();
  final rec = ui.PictureRecorder();
  final c = Canvas(rec)..drawImage(img, Offset.zero, Paint());
  for (final hz in r.hazards) {
    final b = hz.box;
    if (b == null) continue;
    final color = switch (hz.severity) {
      Severity.high => Colors.red,
      Severity.medium => Colors.orange,
      Severity.low => Colors.yellow,
    };
    c.drawRect(
        Rect.fromLTRB(b.left * w, b.top * h, b.right * w, b.bottom * h),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 6
          ..color = color);
  }
  for (final e in r.equipment) {
    final b = Rect.fromLTRB(
        e.box.left * w, e.box.top * h, e.box.right * w, e.box.bottom * h);
    c.drawRect(
        b,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..color = Colors.cyanAccent);
    (TextPainter(
            text: TextSpan(
                text: e.label,
                style: const TextStyle(
                    color: Colors.black,
                    backgroundColor: Colors.cyanAccent,
                    fontSize: 22)),
            textDirection: TextDirection.ltr)
          ..layout())
        .paint(c, b.topLeft);
  }
  final out = await rec.endRecording().toImage(img.width, img.height);
  final png = await out.toByteData(format: ui.ImageByteFormat.png);
  File(path)
    ..createSync(recursive: true)
    ..writeAsBytesSync(png!.buffer.asUint8List());
}
