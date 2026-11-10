import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import '../core/jpeg.dart';
import 'hazard.dart';
import 'hazard_analyzer.dart';
import 'hazard_rules.dart';

/// Gemini REST API 직접 호출. 키·모델은 --dart-define(-from-file)로 주입.
/// ※ 앱에 키를 넣으면 APK에서 추출 가능 → 시연용. 실서비스는 서버 경유.
class GeminiHazardAnalyzer implements HazardAnalyzer {
  /// 인자는 테스트용. 앱에서는 비워 두면 dart-define 값을 씁니다.
  GeminiHazardAnalyzer(
      {http.Client? client,
      String? apiKey,
      String? model,
      String? thinking,
      this.retryDelay = const Duration(seconds: 1)})
      : _client = client ?? http.Client(),
        _key = apiKey ?? const String.fromEnvironment('GEMINI_API_KEY'),
        _model = model ??
            const String.fromEnvironment('GEMINI_MODEL',
                defaultValue: 'gemini-3-flash-preview'),
        _thinking = thinking ??
            const String.fromEnvironment('GEMINI_THINKING',
                defaultValue: 'low');

  final http.Client _client;

  /// 일시적 서버 오류 뒤 다시 시도하기 전 대기(테스트에서는 0)
  final Duration retryDelay;
  final String _key;
  final String _model;

  @override
  String get description =>
      'Gemini $_model${_thinking.isEmpty ? '' : ' · thinking $_thinking'}';

  /// Gemini 3 계열 생각 정도(minimal/low/medium/high). 비우면 모델 기본값.
  /// 위치 찾기 같은 단순 공간 작업은 낮을수록 빠르고 결과도 좋다는 게 Google 안내
  final String _thinking;

  /// 등급(위험·주의·관찰)은 AI가 정하지 않음: AI는 위험을 찾아 **종류(category)만** 고르고,
  /// 등급은 앱의 규칙표([HazardRules])가 정함 → 같은 종류는 언제나 같은 등급(2026-11-10, LLM 의존도 완화)
  static final _prompt = '''
너는 건물 기계실·전기실을 점검하는 시설기사의 안전 보조원이다.
사진에서 사람이 다치거나 설비 사고로 이어질 수 있는 위험요소만 찾아라.
각 위험요소의 사진 속 위치를 box_2d [ymin, xmin, ymax, xmax] (0~1000 정규화)로 표시하라.
각 위험요소의 category는 아래 목록에서 가장 맞는 것 하나를 골라라. 위험 등급은 앱의 규칙표가 정하므로 네가 정하지 않는다. 같은 장면이면 항상 같은 category가 되게 골라라.
${HazardRules.promptList}
고르는 규칙:
- 물은 이 순서로 본다: 바닥의 대부분이 잠겼거나 물이 계속 쏟아지면 flooding. 그렇지 않고 물기·누수가 전기설비(분전반·전동기·전선·콘센트)에 닿거나 바로 옆·아래에 있으면 leak이 아니라 water_near_electrical. 둘 다 아니면 leak.
- 분전반 문이 열려 있으면: 안쪽 단자·모선·접속부가 보이면 live_part_exposed, 보호판에 가려 안 보이면 panel_door_open.
- 쌓인 물건은 무엇을 막는지로 고른다: 분전반 앞이면 panel_obstructed, 소화기·소화전 앞이면 extinguisher_blocked, 통로·출입구·방화문이면 evacuation_blocked, 타기 쉬운 물건을 쌓아 둔 것이면 combustibles_stored, 그 밖의 바닥 물건은 floor_obstacle.
- 녹은 표면 변색·얇은 녹이면 minor_rust, 표면이 들뜨거나 구멍·누설 흔적이 있으면 corrosion.
- 두 종류 사이에서 애매하면 더 조심해야 하는 쪽을 고른다(leak보다 water_near_electrical, minor_rust보다 corrosion, wiring_untidy보다 wire_damaged).
- 같은 것을 종류만 바꿔 두 번 넣지 마라. 한 위험은 한 번만.
- 목록에 맞는 것이 없을 때만 other.
type에는 그 위험을 짧은 말로 적고(예: 바닥 물고임), description에는 사진 속 근거, action에는 기사가 할 조치를 적어라.
확실하지 않으면 추측하지 말고 넣지 마라. 위험이 없으면 hazards는 빈 배열.
모든 문장은 한국어로 짧게.''';

  /// 설비 전용 탐지기 학습용: 위험과 상관없이 보이는 설비를 종류·위치로 모두
  static final _equipmentPrompt = '''
또한 위험 여부와 상관없이 사진에 보이는 설비를 equipment에 하나씩 넣고 각각 box_2d로 위치를 표시하라.
종류: ${Equipment.labels.entries.map((e) => '${e.key}(${e.value})').join(', ')}.
같은 종류가 여러 개면 따로따로. 배관은 보이는 구간마다. 일부만 보여도 넣되, 알아볼 수 없을 만큼 작거나 흐리면 빼라. 최대 30개.''';

  /// 장소를 알면 맨 앞에 붙임: 전기실이면 충전부·분전반, 보일러실이면 배관·압력계처럼
  /// 그 장소에서 흔한 위험을 먼저 보게 됨
  static String promptFor(String? place, {bool equipment = false}) {
    final p = place?.trim() ?? '';
    final base = equipment ? '$_prompt\n$_equipmentPrompt' : _prompt;
    return p.isEmpty ? base : '점검 장소: $p\n$base';
  }

  static Map<String, Object> schemaFor({bool equipment = false}) => equipment
      ? {
          ..._schema,
          'properties': {
            ..._schema['properties'] as Map<String, Object>,
            'equipment': {
              'type': 'ARRAY',
              'items': {
                'type': 'OBJECT',
                'properties': {
                  'label': {
                    'type': 'STRING',
                    'enum': Equipment.labels.keys.toList(),
                  },
                  'box_2d': {
                    'type': 'ARRAY',
                    'description': '[ymin, xmin, ymax, xmax], 0~1000',
                    'items': {'type': 'INTEGER'},
                  },
                },
                'required': ['label', 'box_2d'],
              },
            },
          },
        }
      : _schema;

  static final Map<String, Object> _schema = {
    'type': 'OBJECT',
    'properties': {
      'summary': {'type': 'STRING', 'description': '장면 한 줄 요약'},
      'hazards': {
        'type': 'ARRAY',
        'items': {
          'type': 'OBJECT',
          'properties': {
            'category': {
              'type': 'STRING',
              'description': '위험 종류(목록에서 하나)',
              'enum': HazardRules.keys,
            },
            'type': {'type': 'STRING', 'description': '위험을 짧은 말로'},
            'description': {'type': 'STRING', 'description': '사진 속 근거'},
            'action': {'type': 'STRING', 'description': '기사가 할 조치'},
            'box_2d': {
              'type': 'ARRAY',
              'description': '[ymin, xmin, ymax, xmax], 0~1000',
              'items': {'type': 'INTEGER'},
            },
          },
          'required': ['category', 'type', 'description', 'action'],
        },
      },
    },
    'required': ['summary', 'hazards'],
  };

  @override
  String? get unavailableReason => _key.isEmpty
      ? 'GEMINI_API_KEY 없음 → --dart-define-from-file=secrets.json 로 실행'
      : null;

  @override
  Future<HazardReport> analyze(Uint8List jpeg,
      {String? place, bool equipment = false}) async {
    final reason = unavailableReason;
    if (reason != null) throw StateError(reason);

    final sw = Stopwatch()..start();
    final http.Response res;
    try {
      res = await _postWithRetry(jsonEncode({
        'contents': [
          {
            'parts': [
              {'text': promptFor(place, equipment: equipment)},
              {
                'inlineData': {
                  'mimeType': 'image/jpeg',
                  'data': base64Encode(jpeg),
                }
              },
            ],
          }
        ],
        'generationConfig': {
          'responseMimeType': 'application/json',
          'responseSchema': schemaFor(equipment: equipment),
          // temperature는 기본값 유지(Gemini 3 문서: 낮추면 반복·품질 저하 가능)
          if (_thinking.isNotEmpty)
            'thinkingConfig': {'thinkingLevel': _thinking},
        },
      }));
    } on TimeoutException {
      throw StateError('Gemini 응답 시간 초과(30초). 네트워크 상태를 확인하세요.');
    } on http.ClientException catch (e) {
      // 지하 기계실 등: 기술 문구 대신 할 수 있는 일을 안내
      final offline = e.message.contains('host lookup') ||
          e.message.contains('Network is unreachable') ||
          e.message.contains('Connection refused');
      throw StateError(offline
          ? '인터넷에 연결되어 있지 않습니다. 사진만 저장해 두고 연결되는 곳에서 AI 분석할 수 있어요.'
          : '인터넷 연결을 확인하세요 (${e.message})');
    }
    sw.stop();

    if (res.statusCode != 200) throw StateError(_httpError(res));
    final body = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final text = body['candidates']?[0]?['content']?['parts']?[0]?['text'];
    if (text is! String) {
      final blocked = body['promptFeedback']?['blockReason'] ??
          body['candidates']?[0]?['finishReason'];
      throw StateError(blocked != null
          ? 'Gemini가 응답을 막았습니다($blocked). 다른 장면으로 다시 시도하세요.'
          : 'Gemini 응답 형식 이상: ${res.body}');
    }
    return HazardReport.fromAi(jsonDecode(text) as Map<String, dynamic>,
        sw.elapsedMilliseconds, await encodedImageSize(jpeg));
  }

  /// 일시적인 서버 오류(500·503: 과부하)는 잠깐 쉬고 한 번 더. 모델 비교 때 실제로 503을 받음.
  /// 키 오류·한도 초과(4xx)나 인터넷 끊김은 다시 해도 같으므로 바로 알림
  Future<http.Response> _postWithRetry(String body) async {
    for (var attempt = 1;; attempt++) {
      final res = await _client
          .post(
            Uri.parse(
                'https://generativelanguage.googleapis.com/v1beta/models/$_model:generateContent'),
            headers: {
              'Content-Type': 'application/json',
              'x-goog-api-key': _key
            },
            body: body,
          )
          .timeout(const Duration(seconds: 30));
      final transient = res.statusCode == 500 || res.statusCode == 503;
      if (!transient || attempt >= maxAttempts) return res;
      await Future<void>.delayed(retryDelay);
    }
  }

  static const maxAttempts = 2;

  /// 현장에서 바로 알아볼 수 있게 흔한 오류를 한국어로. 원인 파악용으로 상태코드는 남김
  String _httpError(http.Response res) {
    final code = res.statusCode;
    final body = res.body;
    final hint = switch (code) {
      400
          when body.contains('API_KEY_INVALID') ||
              body.contains('API key not valid') =>
        'API 키가 올바르지 않습니다. secrets.json의 GEMINI_API_KEY를 확인하세요.',
      400 => '요청 형식 오류입니다(이미지·스키마).',
      403 => '이 키로 Gemini API를 쓸 권한이 없습니다(API 사용 설정·지역·결제 확인).',
      404 when body.contains('no longer available') =>
        '$_model 은 새 사용자에게 더 이상 제공되지 않습니다. secrets.json의 GEMINI_MODEL을 최신 모델로 바꾸세요.',
      404 => '모델을 찾을 수 없습니다: $_model (secrets.json의 GEMINI_MODEL 확인).',
      // 무료 키는 하루 한도(2026-11-09 확인: 모델별 하루 20번, 태평양 자정 = 한국 오후 5시쯤 초기화)가
      // 먼저 걸림. 이때 "잠시 후 다시"라고 하면 현장에서 계속 누르게 되므로 사진만 저장하도록 안내
      429 when body.contains('PerDay') =>
        '오늘 AI 사용 한도(무료 키 하루 한도)를 다 썼습니다. 한국 시간 오후 5시쯤 다시 됩니다. '
            '지금은 [사진만 저장]으로 기록해 두고 나중에 분석하세요.',
      429 => '요청 한도를 넘었습니다(짧은 시간에 너무 많이 보냄). 1분쯤 뒤 다시 시도하세요.',
      >= 500 => 'Gemini 서버 오류입니다. 잠시 후 다시 시도하세요.',
      _ => '알 수 없는 오류입니다.',
    };
    final detail = body.length > 300 ? '${body.substring(0, 300)}…' : body;
    return '$hint\n(Gemini $code) $detail';
  }
}
