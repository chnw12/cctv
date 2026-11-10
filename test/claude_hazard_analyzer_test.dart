import 'dart:convert';
import 'dart:io';
import 'package:facility_camera/analysis/claude_hazard_analyzer.dart';
import 'package:facility_camera/analysis/default_analyzer.dart';
import 'package:facility_camera/analysis/fake_hazard_analyzer.dart';
import 'package:facility_camera/analysis/gemini_hazard_analyzer.dart';
import 'package:facility_camera/analysis/hazard.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Claude 응답 모양(content 블록 배열). 생각 블록이 앞에 와도 글자 블록을 찾아야 함
http.Response _ok(Map<String, Object?> answer, {String stop = 'end_turn'}) =>
    http.Response(
        jsonEncode({
          'model': 'claude-sonnet-5-5',
          'stop_reason': stop,
          'content': [
            {'type': 'thinking', 'thinking': '', 'signature': 'x'},
            {'type': 'text', 'text': jsonEncode(answer)},
          ],
          'usage': {'input_tokens': 2200, 'output_tokens': 400},
        }),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'});

const _answer = {
  'summary': '기계실 배관과 분전반',
  'hazards': [
    {
      'type': '바닥 누수',
      'description': '바닥에 물웅덩이',
      'severity': 'medium',
      'action': '누수 지점 확인 후 건조',
      'box_2d': [800, 300, 880, 650],
    }
  ],
};

void main() {
  final jpeg = File('assets/test_frames/scene_01.jpg').readAsBytesSync();

  test('요청 형식: 키 헤더·API 버전·사진·같은 지시문·JSON 스키마 / 응답 → HazardReport', () async {
    late http.Request sent;
    final a = ClaudeHazardAnalyzer(
        client: MockClient((req) async {
          sent = req;
          return _ok(_answer);
        }),
        apiKey: 'test-key');
    final r = await a.analyze(jpeg, place: 'B2 기계실');

    expect(sent.url.toString(), 'https://api.anthropic.com/v1/messages');
    expect(sent.headers['x-api-key'], 'test-key');
    expect(sent.headers['anthropic-version'], '2026-10-21');
    final body = jsonDecode(sent.body) as Map<String, dynamic>;
    expect(body['model'], 'claude-sonnet-5-5'); // 앱 기본 모델
    expect(body['output_config']['effort'], 'low');
    expect(body['output_config']['format']['type'], 'json_schema');
    // 새 API 버전은 temperature 등을 받지 않음(보내면 400)
    expect(body.keys, isNot(contains('temperature')));
    final content = body['messages'][0]['content'] as List;
    expect(content[0]['source']['media_type'], 'image/jpeg');
    expect(base64Decode(content[0]['source']['data']), jpeg);
    // Gemini와 글자 하나 다르지 않은 지시문(두 AI 비교·등급 기준이 같아야 함)
    expect(content[1]['text'], GeminiHazardAnalyzer.promptFor('B2 기계실'));

    expect(r.summary, '기계실 배관과 분전반');
    expect(r.hazards.single.severity, Severity.medium);
    expect(r.hazards.single.box!.left, closeTo(0.3, 1e-9));
    expect(r.imageSize.width, 1080);
    expect(a.lastUsage!['output_tokens'], 400);
    expect(a.description, 'Claude claude-sonnet-5-5 · effort low');
  });

  test('키 없으면 호출하지 않고 이유를 알려줌 · 따옴표로 감싼 키는 벗겨서 보냄', () async {
    var called = false;
    final none = ClaudeHazardAnalyzer(
        client: MockClient((_) async {
          called = true;
          return http.Response('', 500);
        }),
        apiKey: '');
    expect(none.unavailableReason, contains('CLAUDE_API_KEY'));
    await expectLater(none.analyze(jpeg), throwsStateError);
    expect(called, isFalse);

    late http.Request sent;
    await ClaudeHazardAnalyzer(
        client: MockClient((req) async {
          sent = req;
          return _ok(_answer);
        }),
        apiKey: '"quoted-key"').analyze(jpeg);
    expect(sent.headers['x-api-key'], 'quoted-key');
  });

  test('설비 위치도 받을 때는 답 형식에 equipment가 들어감', () {
    final plain = ClaudeHazardAnalyzer.schemaFor();
    final withEq = ClaudeHazardAnalyzer.schemaFor(equipment: true);
    expect((plain['properties'] as Map).keys, isNot(contains('equipment')));
    expect(withEq['required'], contains('equipment'));
    expect(
        (withEq['properties'] as Map)['equipment']['items']['properties']
            ['label']['enum'],
        Equipment.labels.keys.toList());
  });

  test('서버 과부하(529)는 한 번 더 시도해서 성공, 키 오류(401)는 다시 안 함', () async {
    var calls = 0;
    final r = await ClaudeHazardAnalyzer(
        client: MockClient((_) async =>
            ++calls == 1 ? http.Response('{"error":{}}', 529) : _ok(_answer)),
        apiKey: 'k',
        retryDelay: Duration.zero).analyze(jpeg);
    expect(calls, 2);
    expect(r.hazards, hasLength(1));

    calls = 0;
    await expectLater(
        ClaudeHazardAnalyzer(
            client: MockClient((_) async {
              calls++;
              return http.Response('{"error":{}}', 401);
            }),
            apiKey: 'k',
            retryDelay: Duration.zero).analyze(jpeg),
        throwsStateError);
    expect(calls, 1);
  });

  group('흔한 오류는 현장에서 알아볼 수 있는 한국어로', () {
    Future<String> errorOf(http.Response Function() res) async {
      try {
        await ClaudeHazardAnalyzer(
            client: MockClient((_) async => res()),
            apiKey: 'k',
            retryDelay: Duration.zero).analyze(jpeg);
      } on StateError catch (e) {
        return e.message;
      }
      fail('오류가 나야 함');
    }

    test('잘못된 키', () async {
      final m = await errorOf(() => http.Response('{}', 401));
      expect(m, contains('API 키가 올바르지 않습니다'));
      expect(m, contains('(Claude 401)'));
    });
    test('요금(크레딧) 부족은 사진만 저장하도록 안내', () async {
      for (final res in [
        http.Response('{"error":{"type":"billing_error"}}', 402),
        http.Response(
            '{"error":{"message":"Your credit balance is too low"}}', 400),
      ]) {
        final m = await errorOf(() => res);
        expect(m, contains('요금'));
        expect(m, contains('사진만 저장'));
      }
    });
    test('한도 초과 · 모델 이름 오류 · 서버 오류', () async {
      expect(await errorOf(() => http.Response('{}', 429)), contains('요청 한도'));
      expect(await errorOf(() => http.Response('{}', 404)),
          contains('claude-sonnet-5-5'));
      expect(await errorOf(() => http.Response('{}', 500)), contains('서버 오류'));
    });
    test('거절(refusal)·길이 제한은 결과로 읽지 않고 알림', () async {
      expect(await errorOf(() => _ok(_answer, stop: 'refusal')),
          contains('거절'));
      expect(await errorOf(() => _ok(_answer, stop: 'max_tokens')),
          contains('길이 제한'));
    });
    test('인터넷 없음(DNS 실패)은 할 수 있는 일을 안내', () async {
      final m = await errorOf(
          () => throw http.ClientException('Failed host lookup: api'));
      expect(m, contains('인터넷에 연결되어 있지 않습니다'));
      expect(m, contains('사진만 저장'));
    });
  });

  test('앱이 쓸 AI 고르기: 지정하면 그대로, 비우면 쓸 수 있는 쪽(둘 다 되면 Claude)', () {
    final claude = ClaudeHazardAnalyzer(apiKey: 'c');
    final noClaude = ClaudeHazardAnalyzer(apiKey: '');
    final gemini = GeminiHazardAnalyzer(apiKey: 'g');
    final noGemini = GeminiHazardAnalyzer(apiKey: '');
    final fake = FakeHazardAnalyzer();

    expect(pickAnalyzer('claude', claude: noClaude, gemini: gemini), noClaude);
    expect(pickAnalyzer('Gemini', claude: claude, gemini: gemini), gemini);
    expect(pickAnalyzer('', claude: claude, gemini: gemini), claude);
    expect(pickAnalyzer('', claude: noClaude, gemini: gemini), gemini);
    // 둘 다 키가 없으면 Claude 쪽 안내(키 넣는 법)를 보여 줌
    expect(pickAnalyzer('', claude: noClaude, gemini: noGemini), noClaude);
    expect(pickAnalyzer('', claude: claude, gemini: fake), claude);
  });
}
