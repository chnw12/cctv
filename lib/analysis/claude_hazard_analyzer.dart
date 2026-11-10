import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import '../core/jpeg.dart';
import 'gemini_hazard_analyzer.dart' show GeminiHazardAnalyzer;
import 'hazard.dart';
import 'hazard_analyzer.dart';

/// Claude Messages API 직접 호출(다트용 공식 SDK가 없어 HTTP로). 키·모델은 --dart-define(-from-file)로 주입.
/// Gemini와 **같은 지시문·같은 답 형식**이라 두 AI를 같은 사진으로 비교할 수 있음(test/scene_eval_test.dart).
/// 2026-11-10 앱 기본 AI를 Claude Sonnet 5.5로: 공개 기계실 사진 16장 × 3번 비교에서 같은 사진의 최고 등급이
/// 매번 같은 비율 88%(Opus 5.5 81%), 응답 4.1초(Opus 6.2초, Gemini 3 Flash는 같은 사진에서 4.2초),
/// 위험의 99%에 위치 박스. Gemini 무료 키의 하루 20번 한도도 없음(대신 쓴 만큼 요금 — 콘솔에서 지출 한도 필수).
/// ※ 앱에 키를 넣으면 APK에서 추출 가능 → 시연용(APK는 팀 안에서만, 대회 뒤 키 삭제). 실서비스는 서버 경유.
class ClaudeHazardAnalyzer implements HazardAnalyzer {
  /// 인자는 테스트·비교 시험용. 앱에서는 비워 두면 dart-define 값을 씁니다.
  ClaudeHazardAnalyzer({
    http.Client? client,
    String? apiKey,
    String? model,
    String? effort,
    this.retryDelay = const Duration(seconds: 1),
    this.timeout = const Duration(seconds: 30),
  })  : _client = client ?? http.Client(),
        _key = _unquote(apiKey ??
            const String.fromEnvironment('CLAUDE_API_KEY',
                defaultValue: String.fromEnvironment('CLAUDE_EVAL_KEY'))),
        model = model ??
            const String.fromEnvironment('CLAUDE_MODEL',
                defaultValue: 'claude-sonnet-5-5'),
        effort = effort ??
            const String.fromEnvironment('CLAUDE_EFFORT', defaultValue: 'low');

  final http.Client _client;
  final String _key;
  final String model;

  /// 생각 깊이(low/medium/high). 기본 low = 비교 시험에서 잰 설정(빠름)
  final String effort;

  /// 일시적 서버 오류 뒤 다시 시도하기 전 대기(테스트에서는 0)
  final Duration retryDelay;
  final Duration timeout;

  /// 마지막 호출의 토큰 사용량(비용 어림용)
  Map<String, dynamic>? lastUsage;

  /// .env에 따옴표로 감싸 적어도 되게("sk-…" → sk-…)
  static String _unquote(String s) {
    final t = s.trim();
    final quoted = t.length >= 2 &&
        (t.startsWith('"') && t.endsWith('"') ||
            t.startsWith("'") && t.endsWith("'"));
    return quoted ? t.substring(1, t.length - 1) : t;
  }

  @override
  String? get unavailableReason => _key.isEmpty
      ? 'CLAUDE_API_KEY 없음 → --dart-define-from-file=.env 를 붙여 빌드'
      : null;

  @override
  String get description => 'Claude $model · effort $effort';

  /// Gemini 답 형식(GeminiHazardAnalyzer.schemaFor)과 같은 내용의 JSON Schema
  static Map<String, Object> schemaFor({bool equipment = false}) {
    const box = {
      'type': 'array',
      'description': '[ymin, xmin, ymax, xmax], 0~1000',
      'items': {'type': 'integer'},
    };
    return {
      'type': 'object',
      'properties': {
        'summary': {'type': 'string', 'description': '장면 한 줄 요약'},
        'hazards': {
          'type': 'array',
          'items': {
            'type': 'object',
            'properties': {
              'type': {'type': 'string', 'description': '위험 종류(짧게)'},
              'description': {'type': 'string', 'description': '사진 속 근거'},
              'severity': {
                'type': 'string',
                'enum': ['high', 'medium', 'low'],
              },
              'action': {'type': 'string', 'description': '기사가 할 조치'},
              'box_2d': box,
            },
            'required': ['type', 'description', 'severity', 'action'],
            'additionalProperties': false,
          },
        },
        if (equipment)
          'equipment': {
            'type': 'array',
            'items': {
              'type': 'object',
              'properties': {
                'label': {
                  'type': 'string',
                  'enum': Equipment.labels.keys.toList(),
                },
                'box_2d': box,
              },
              'required': ['label', 'box_2d'],
              'additionalProperties': false,
            },
          },
      },
      'required': ['summary', 'hazards', if (equipment) 'equipment'],
      'additionalProperties': false,
    };
  }

  @override
  Future<HazardReport> analyze(Uint8List jpeg,
      {String? place, bool equipment = false}) async {
    final reason = unavailableReason;
    if (reason != null) throw StateError(reason);

    final sw = Stopwatch()..start();
    final http.Response res;
    try {
      res = await _postWithRetry(jsonEncode({
        'model': model,
        'max_tokens': 16000,
        'output_config': {
          'effort': effort,
          'format': {
            'type': 'json_schema',
            'schema': schemaFor(equipment: equipment),
          },
        },
        'messages': [
          {
            'role': 'user',
            'content': [
              {
                'type': 'image',
                'source': {
                  'type': 'base64',
                  'media_type': 'image/jpeg',
                  'data': base64Encode(jpeg),
                },
              },
              {
                'type': 'text',
                'text':
                    GeminiHazardAnalyzer.promptFor(place, equipment: equipment),
              },
            ],
          }
        ],
      }));
    } on TimeoutException {
      throw StateError(
          'AI 응답 시간 초과(${timeout.inSeconds}초). 네트워크 상태를 확인하세요.');
    } on http.ClientException catch (e) {
      // 지하 기계실 등: 기술 문구 대신 할 수 있는 일을 안내(Gemini 쪽과 같은 문구)
      final offline = e.message.contains('host lookup') ||
          e.message.contains('Network is unreachable') ||
          e.message.contains('Connection refused');
      throw StateError(offline
          ? '인터넷에 연결되어 있지 않습니다. 사진만 저장해 두고 연결되는 곳에서 AI 분석할 수 있어요.'
          : '인터넷 연결을 확인하세요 (${e.message})');
    }
    sw.stop();

    final raw = utf8.decode(res.bodyBytes);
    if (res.statusCode != 200) throw StateError(_httpError(res.statusCode, raw));
    final body = jsonDecode(raw) as Map<String, dynamic>;
    lastUsage = body['usage'] as Map<String, dynamic>?;
    final stop = body['stop_reason'];
    if (stop == 'refusal') {
      throw StateError('AI가 이 사진의 분석을 거절했습니다(refusal). 다른 각도로 다시 찍어 보세요.');
    }
    if (stop == 'max_tokens') {
      throw StateError('AI 응답이 길이 제한에 걸렸습니다. 다시 시도하세요.');
    }
    final text = [
      for (final b in (body['content'] as List? ?? const []))
        if (b is Map && b['type'] == 'text') b['text']
    ].firstOrNull;
    if (text is! String) throw StateError('Claude 응답 형식 이상: ${_clip(raw)}');
    return HazardReport.fromJson(jsonDecode(text) as Map<String, dynamic>,
        sw.elapsedMilliseconds, await encodedImageSize(jpeg));
  }

  /// 일시적인 서버 오류(500, 529 과부하)는 잠깐 쉬고 한 번 더.
  /// 키·요금·한도(4xx)나 인터넷 끊김은 다시 해도 같으므로 바로 알림
  Future<http.Response> _postWithRetry(String body) async {
    for (var attempt = 1;; attempt++) {
      final res = await _client
          .post(
            Uri.parse('https://api.anthropic.com/v1/messages'),
            headers: {
              'content-type': 'application/json',
              'x-api-key': _key,
              'anthropic-version': '2026-10-21',
            },
            body: body,
          )
          .timeout(timeout);
      final transient = res.statusCode == 500 || res.statusCode == 529;
      if (!transient || attempt >= maxAttempts) return res;
      await Future<void>.delayed(retryDelay);
    }
  }

  static const maxAttempts = 2;

  static String _clip(String s) =>
      s.length > 300 ? '${s.substring(0, 300)}…' : s;

  /// 현장에서 바로 알아볼 수 있게 흔한 오류를 한국어로. 원인 파악용으로 상태코드는 남김
  String _httpError(int code, String body) {
    final hint = switch (code) {
      400 when body.contains('credit balance') =>
        'AI 사용 요금(크레딧)이 모자랍니다. Claude 콘솔에서 충전하거나 지출 한도를 확인하세요. '
            '지금은 [사진만 저장]으로 기록해 두고 나중에 분석하세요.',
      400 => '요청 형식 오류입니다(이미지·스키마).',
      401 => 'API 키가 올바르지 않습니다. .env의 키를 확인하고 다시 빌드하세요.',
      402 => 'AI 사용 요금 문제입니다(결제·크레딧). Claude 콘솔을 확인하세요. '
          '지금은 [사진만 저장]으로 기록해 두고 나중에 분석하세요.',
      403 => '이 키로 이 모델을 쓸 권한이 없습니다.',
      404 => '모델을 찾을 수 없습니다: $model (CLAUDE_MODEL 확인).',
      413 => '사진이 너무 큽니다.',
      429 => '요청 한도를 넘었습니다(짧은 시간에 너무 많이 보냄). 1분쯤 뒤 다시 시도하세요.',
      529 => 'AI 서버가 붐빕니다. 잠시 후 다시 시도하세요.',
      >= 500 => 'AI 서버 오류입니다. 잠시 후 다시 시도하세요.',
      _ => '알 수 없는 오류입니다.',
    };
    return '$hint\n(Claude $code) ${_clip(body)}';
  }
}
