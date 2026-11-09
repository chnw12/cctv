import 'dart:convert';
import 'dart:io';
import 'package:facility_camera/analysis/gemini_hazard_analyzer.dart';
import 'package:facility_camera/analysis/hazard.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  final jpeg = File('assets/test_frames/scene_01.jpg').readAsBytesSync();

  test('요청 형식: 키 헤더·이미지·JSON 스키마 / 응답 → HazardReport', () async {
    late http.Request sent;
    final client = MockClient((req) async {
      sent = req;
      final answer = jsonEncode({
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
      });
      return http.Response(
          jsonEncode({
            'candidates': [
              {
                'content': {
                  'parts': [
                    {'text': answer}
                  ]
                }
              }
            ]
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    });

    final a =
        GeminiHazardAnalyzer(client: client, apiKey: 'test-key', model: 'm');
    final r = await a.analyze(jpeg);

    expect(sent.url.path, '/v1beta/models/m:generateContent');
    expect(sent.headers['x-goog-api-key'], 'test-key');
    final body = jsonDecode(sent.body) as Map<String, dynamic>;
    final parts = body['contents'][0]['parts'] as List;
    expect(base64Decode(parts[1]['inlineData']['data']), jpeg);
    expect(body['generationConfig']['responseMimeType'], 'application/json');

    expect(r.summary, '기계실 배관과 분전반');
    expect(r.hazards.single.severity, Severity.medium);
    expect(r.hazards.single.box!.left, closeTo(0.3, 1e-9));
    expect(r.imageSize.width, 1080);
    expect(r.imageSize.height, 1440);
  });

  test('키 없으면 호출하지 않고 이유를 알려줌', () async {
    var called = false;
    final a = GeminiHazardAnalyzer(
        client: MockClient((_) async {
          called = true;
          return http.Response('', 500);
        }),
        apiKey: '');
    expect(a.unavailableReason, contains('GEMINI_API_KEY'));
    await expectLater(a.analyze(jpeg), throwsStateError);
    expect(called, isFalse);
  });

  test('HTTP 오류는 상태코드와 함께 전달', () async {
    final a = GeminiHazardAnalyzer(
        client: MockClient((_) async => http.Response('quota', 429)),
        apiKey: 'k');
    await expectLater(
        a.analyze(jpeg),
        throwsA(isA<StateError>()
            .having((e) => e.message, 'message', contains('429'))));
  });

  test('지시문에 심각도 기준표: 등급별 기준과 "물기 + 전기 = high" 규칙', () {
    final p = GeminiHazardAnalyzer.promptFor(null);
    expect(p, contains('severity는 아래 기준으로만'));
    for (final s in ['- high:', '- medium:', '- low:']) {
      expect(p, contains(s));
    }
    expect(p, contains('바닥에 널린 부품')); // 개발 동기(바닥 적치물)
    expect(p, contains('함께 보이면 반드시 high'));
  });

  test('점검 장소를 프롬프트 맨 앞에 넣음(없으면 그대로)', () async {
    expect(GeminiHazardAnalyzer.promptFor(null), isNot(contains('점검 장소')));
    expect(GeminiHazardAnalyzer.promptFor('  '), isNot(contains('점검 장소')));
    expect(GeminiHazardAnalyzer.promptFor('3층 전기실'),
        startsWith('점검 장소: 3층 전기실\n'));

    late String sentText;
    final a = GeminiHazardAnalyzer(
        client: MockClient((req) async {
          sentText = (jsonDecode(req.body)['contents'][0]['parts'][0]
              as Map)['text'] as String;
          return http.Response('{}', 500);
        }),
        apiKey: 'k',
        retryDelay: Duration.zero);
    await expectLater(a.analyze(jpeg, place: 'B2 기계실'), throwsStateError);
    expect(sentText, startsWith('점검 장소: B2 기계실'));
  });

  test('서버 과부하(503)는 한 번 더 시도해서 성공, 키 오류(400)는 다시 안 함', () async {
    var calls = 0;
    final ok = jsonEncode({
      'candidates': [
        {
          'content': {
            'parts': [
              {
                'text': jsonEncode({'summary': '정상', 'hazards': []})
              }
            ]
          }
        }
      ]
    });
    final a = GeminiHazardAnalyzer(
        client: MockClient((_) async => ++calls == 1
            ? http.Response('busy', 503)
            : http.Response(ok, 200,
                headers: {'content-type': 'application/json; charset=utf-8'})),
        apiKey: 'k',
        retryDelay: Duration.zero);
    expect((await a.analyze(jpeg)).summary, '정상');
    expect(calls, 2);

    var badCalls = 0;
    final bad = GeminiHazardAnalyzer(
        client: MockClient((_) async {
          badCalls++;
          return http.Response('API key not valid', 400);
        }),
        apiKey: 'k',
        retryDelay: Duration.zero);
    await expectLater(bad.analyze(jpeg), throwsStateError);
    expect(badCalls, 1);
  });

  group('흔한 오류는 현장에서 알아볼 수 있는 한국어로', () {
    Future<String> errorOf(http.Response r) async {
      final a = GeminiHazardAnalyzer(
          client: MockClient((_) async => r), apiKey: 'k', model: 'my-model');
      try {
        await a.analyze(jpeg);
      } on StateError catch (e) {
        return e.message;
      }
      fail('예외가 나야 함');
    }

    test('잘못된 키', () async {
      expect(
          await errorOf(http.Response(
              '{"error":{"message":"API key not valid.","status":"INVALID_ARGUMENT"}}',
              400)),
          contains('API 키가 올바르지 않습니다'));
    });
    test('모델 이름 오류는 모델 이름을 보여 줌', () async {
      expect(await errorOf(http.Response('{"error":{}}', 404)),
          allOf(contains('모델을 찾을 수 없습니다'), contains('my-model')));
    });
    test('한도 초과', () async {
      expect(await errorOf(http.Response('{}', 429)), contains('한도'));
    });
    test('하루 한도 초과(무료 키)는 "잠시 후"가 아니라 오후 5시·사진만 저장 안내', () async {
      // 2026-11-09 실제로 받은 429의 한도 이름(값은 20)
      const body = '{"error":{"code":429,"status":"RESOURCE_EXHAUSTED","details":[{'
          '"violations":[{"quotaId":"GenerateRequestsPerDayPerProjectPerModel-FreeTier",'
          '"quotaValue":"20"}]}]}}';
      final e = await errorOf(http.Response(body, 429));
      expect(e, allOf(contains('오늘 AI 사용 한도'), contains('오후 5시'),
          contains('[사진만 저장]')));
      expect(e, isNot(contains('1분쯤 뒤')));
      // 분당 한도면 1분 뒤 다시
      final m = await errorOf(http.Response(
          '{"error":{"details":[{"violations":[{"quotaId":'
          '"GenerateRequestsPerMinutePerProjectPerModel-FreeTier"}]}]}}',
          429));
      expect(m, contains('1분쯤 뒤'));
    });
    test('안전 필터로 막힌 응답', () async {
      expect(
          await errorOf(http.Response(
              '{"promptFeedback":{"blockReason":"SAFETY"}}', 200)),
          contains('막았습니다(SAFETY)'));
    });
    test('인터넷 없음(DNS 실패)은 할 수 있는 일을 안내', () async {
      final a = GeminiHazardAnalyzer(
          client: MockClient((_) async => throw http.ClientException(
              "Failed host lookup: 'generativelanguage.googleapis.com'")),
          apiKey: 'k');
      await expectLater(
          a.analyze(jpeg),
          throwsA(isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(
                  contains('인터넷에 연결되어 있지 않습니다'), isNot(contains('lookup'))))));
    });
    test('네트워크 끊김', () async {
      final a = GeminiHazardAnalyzer(
          client:
              MockClient((_) async => throw http.ClientException('no route')),
          apiKey: 'k');
      await expectLater(
          a.analyze(jpeg),
          throwsA(isA<StateError>()
              .having((e) => e.message, 'message', contains('인터넷 연결'))));
    });
  });
}
