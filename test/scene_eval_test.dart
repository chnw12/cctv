import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:facility_camera/analysis/claude_hazard_analyzer.dart';
import 'package:facility_camera/analysis/gemini_hazard_analyzer.dart';
import 'package:facility_camera/analysis/hazard.dart';
import 'package:facility_camera/analysis/hazard_analyzer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 같은 사진을 실제 Gemini에 여러 번 보내 위험 판단이 매번 같은지(일관성) 모으기. 평소엔 건너뜀(키가 있을 때만).
///   flutter test test/scene_eval_test.dart --dart-define-from-file=secrets.json -r expanded
/// 사진 준비·보고서는 tool/scene_eval.py (search → fetch → 팀 정답 적기 → 이 테스트 → report).
/// 바꿀 수 있는 것(--dart-define):
///   SCENE_DIR    사진 폴더(기본 build/scene_eval/images, 시험 그림은 assets/test_frames)
///   SCENE_REPEAT 사진마다 몇 번(기본 5)
///   SCENE_GAP_MS 호출 사이 쉬는 시간(기본 7000 — 무료 키 분당 한도)
///   SCENE_PLACE  점검 장소(앱처럼 지시문 앞에 붙음, 기본 없음)
///   SCENE_FRESH  true면 지난 결과를 버리고 처음부터(기본은 성공한 것은 건너뛰고 이어서)
///   SCENE_TAG    결과 파일 이름 뒤에 붙일 꼬리표(예: rules) — 지시문·규칙을 바꾼 전후를 따로 남길 때
///   SCENE_MAX_CALLS 이번에 쓸 최대 호출 수(기본 0 = 제한 없음). 하루 한도 일부를 폰 점검용으로 남길 때
/// 결과: build/scene_eval/results.jsonl(한 줄 = 한 번 호출), annotated/<사진>.png(첫 실행 박스)
/// 무료 키는 모델마다 하루 20번까지라(2026-11-09 확인, 한국 시간 오후 5시쯤 초기화) 한 번에 다 못 돌 수 있음 →
/// 1분 쉬어도 한도면 멈추고, 다음에 같은 명령으로 이어서 함
///
/// Claude로 같은 시험(같은 지시문, 비교용. 키는 .env의 CLAUDE_EVAL_KEY — 저장소·앱에 안 들어감):
///   flutter test test/scene_eval_test.dart --dart-define-from-file=.env --dart-define=SCENE_PROVIDER=claude
///     --dart-define=SCENE_MODEL=claude-opus-5-5 --dart-define=SCENE_REPEAT=3 -r expanded
///   SCENE_MODEL  claude-opus-5-5(기본) / claude-sonnet-5-5 등,  SCENE_EFFORT  low(기본) / medium / high
///   결과: results_<모델>.jsonl, annotated_<모델>/ (Gemini 결과와 섞이지 않음) → python tool/scene_eval.py compare
/// 키는 헤더로만 보내고 어디에도 출력하지 않습니다.
const _key = String.fromEnvironment('GEMINI_API_KEY');
const _provider =
    String.fromEnvironment('SCENE_PROVIDER', defaultValue: 'gemini');
const _claude = _provider == 'claude';
const _claudeKey = String.fromEnvironment('CLAUDE_EVAL_KEY');
const _claudeModel =
    String.fromEnvironment('SCENE_MODEL', defaultValue: 'claude-opus-5-5');
const _claudeEffort =
    String.fromEnvironment('SCENE_EFFORT', defaultValue: 'low');
const _model = String.fromEnvironment('GEMINI_MODEL',
    defaultValue: 'gemini-3-flash-preview');
const _thinking =
    String.fromEnvironment('GEMINI_THINKING', defaultValue: 'low');
const _dir =
    String.fromEnvironment('SCENE_DIR', defaultValue: 'build/scene_eval/images');
const _repeat = int.fromEnvironment('SCENE_REPEAT', defaultValue: 5);
const _gapMs =
    int.fromEnvironment('SCENE_GAP_MS', defaultValue: _claude ? 1000 : 7000);
const _place = String.fromEnvironment('SCENE_PLACE');
const _fresh = bool.fromEnvironment('SCENE_FRESH');
const _maxCalls = int.fromEnvironment('SCENE_MAX_CALLS');
const _out = 'build/scene_eval';
// 지시문·규칙을 바꾼 뒤 같은 사진으로 다시 잴 때: SCENE_TAG=rules → results_<모델>-rules.jsonl(앞선 결과를 덮지 않음)
const _runTag = String.fromEnvironment('SCENE_TAG');
const _sfx = _runTag == '' ? '' : '-$_runTag';
const _tag = _claude
    ? '$_claudeModel+$_claudeEffort$_sfx'
    : '$_model${_thinking == '' ? '' : '+$_thinking'}$_sfx';
const _results = _claude
    ? '$_out/results_$_claudeModel$_sfx.jsonl'
    : '$_out/results$_sfx.jsonl';
const _annotated = _claude
    ? '$_out/annotated_$_claudeModel$_sfx'
    : '$_out/annotated$_sfx';

void main() {
  final dir = Directory(_dir);
  final images = dir.existsSync()
      ? (dir
          .listSync()
          .whereType<File>()
          .where((f) =>
              RegExp(r'\.(jpe?g)$', caseSensitive: false).hasMatch(f.path))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path)))
      : <File>[];
  final skip = _claude && _claudeKey.isEmpty
      ? 'CLAUDE_EVAL_KEY 없음 (--dart-define-from-file=.env)'
      : !_claude && _key.isEmpty
          ? 'GEMINI_API_KEY 없음 (--dart-define-from-file=secrets.json)'
          : images.isEmpty
              ? '$_dir 에 사진 없음 (tool/scene_eval.py fetch 먼저)'
              : null;

  test('같은 사진 반복 분석($_tag): ${images.length}장 × $_repeat번', () async {
    final HazardAnalyzer analyzer = _claude
        ? ClaudeHazardAnalyzer(
            apiKey: _claudeKey, model: _claudeModel, effort: _claudeEffort)
        : GeminiHazardAnalyzer(apiKey: _key, model: _model, thinking: _thinking);
    // 이어 하기: 이미 성공한 (사진, 회차)는 건너뜀. 실패 줄은 지우고 다시 시도(SCENE_FRESH=true면 처음부터)
    final out = File(_results)..createSync(recursive: true);
    final kept = _fresh
        ? <String>[]
        : [
            for (final l in out.readAsLinesSync())
              if (l.trim().isNotEmpty &&
                  !(jsonDecode(l) as Map).containsKey('error'))
                l
          ];
    final done = {
      for (final l in kept)
        '${(jsonDecode(l) as Map)['file']}#${(jsonDecode(l) as Map)['run']}'
    };
    out.writeAsStringSync(kept.map((l) => '$l\n').join());
    final sink = out.openWrite(mode: FileMode.append);
    var calls = 0, fails = 0;
    if (done.isNotEmpty) {
      // ignore: avoid_print
      print('이어 하기: 이미 성공한 ${done.length}번은 건너뜀');
    }
    try {
      outer:
      for (final f in images) {
        final name = f.uri.pathSegments.last;
        final jpeg = f.readAsBytesSync();
        for (var run = 1; run <= _repeat; run++) {
          if (done.contains('$name#$run')) continue;
          if (_maxCalls > 0 && calls >= _maxCalls) {
            // ignore: avoid_print
            print('\n이번 몫($_maxCalls번)을 다 씀 → 멈춤(남은 한도는 폰 점검용). 다음에 같은 명령으로 이어서');
            break outer;
          }
          if (calls++ > 0) {
            await Future<void>.delayed(const Duration(milliseconds: _gapMs));
          }
          final line = <String, Object?>{
            'file': name,
            'run': run,
            'model': _tag,
          };
          try {
            final r = await _analyzeWithWait(analyzer, jpeg);
            line
              ..['ms'] = r.elapsedMs
              ..['summary'] = r.summary
              ..['hazards'] = [for (final h in r.hazards) h.toJson()];
            if (analyzer is ClaudeHazardAnalyzer) {
              line['usage'] = analyzer.lastUsage; // 비용 어림용 토큰 수
            }
            // ignore: avoid_print
            print('$name #$run ${r.elapsedMs}ms 위험 ${r.hazards.length}개: '
                '${r.hazards.map((h) => '${h.severity.name} ${h.category ?? '-'} ${h.type}').join(' · ')}');
            if (run == 1) {
              await _saveAnnotated(jpeg, r, '$_annotated/$name.png');
            }
          } on _DailyLimit {
            // 1분 쉬어도 또 429 = 하루 한도(무료 키는 모델마다 하루 20번). 더 해도 다 실패하므로 멈춤
            // ignore: avoid_print
            print('\n요청 한도가 1분 뒤에도 그대로 → 하루 한도로 보고 멈춤. '
                '한도가 풀린 뒤(한국 시간 오후 5시쯤) 같은 명령으로 다시 돌리면 이어서 합니다.');
            break outer;
          } catch (e) {
            fails++;
            line['error'] = e is StateError ? e.message : '$e';
            // ignore: avoid_print
            print('$name #$run 실패: ${line['error'].toString().split('\n').first}');
          }
          sink.writeln(jsonEncode(line));
        }
      }
    } finally {
      await sink.close();
    }
    // ignore: avoid_print
    print('\n이번에 호출 $calls번, 실패 $fails번 · 성공 누적 '
        '${out.readAsLinesSync().where((l) => l.trim().isNotEmpty && !l.contains('"error"')).length}번'
        ' → ${out.path}\n보고서: python tool/scene_eval.py '
        '${_claude ? 'compare' : 'report'}');
  }, skip: skip, timeout: Timeout.none);
}

class _DailyLimit implements Exception {}

bool _is429(Object e) =>
    e is StateError &&
    (e.message.contains('(Gemini 429)') || e.message.contains('(Claude 429)'));

/// 분당 한도(429)면 1분 쉬고 한 번 더. 그래도 429면 하루 한도
Future<HazardReport> _analyzeWithWait(HazardAnalyzer a, Uint8List jpeg) async {
  final place = _place.isEmpty ? null : _place;
  try {
    return await a.analyze(jpeg, place: place);
  } catch (e) {
    if (!_is429(e)) rethrow;
    // ignore: avoid_print
    print('  요청 한도 → 60초 쉬고 다시');
    await Future<void>.delayed(const Duration(seconds: 60));
    try {
      return await a.analyze(jpeg, place: place);
    } catch (e2) {
      if (_is429(e2)) throw _DailyLimit();
      rethrow;
    }
  }
}

/// 원본 위에 위험 박스·이름을 그려 PNG로
Future<void> _saveAnnotated(
    Uint8List jpeg, HazardReport r, String path) async {
  final codec = await ui.instantiateImageCodec(jpeg);
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
    final rect =
        Rect.fromLTRB(b.left * w, b.top * h, b.right * w, b.bottom * h);
    c.drawRect(
        rect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4
          ..color = color);
    (TextPainter(
            text: TextSpan(
                text: hz.severity.name,
                style: TextStyle(
                    color: Colors.black, backgroundColor: color, fontSize: 18)),
            textDirection: TextDirection.ltr)
          ..layout())
        .paint(c, rect.topLeft);
  }
  final out = await rec.endRecording().toImage(img.width, img.height);
  final png = await out.toByteData(format: ui.ImageByteFormat.png);
  File(path)
    ..createSync(recursive: true)
    ..writeAsBytesSync(png!.buffer.asUint8List());
}
