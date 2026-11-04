import 'dart:convert';
import 'dart:io';
import 'dart:ui';
import 'package:facility_camera/analysis/gemini_hazard_analyzer.dart';
import 'package:facility_camera/analysis/hazard.dart';
import 'package:facility_camera/data/equipment_dataset.dart';
import 'package:facility_camera/detection/equipment_detector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 설비 박스(탐지기 학습 데이터): Gemini 요청·응답, 저장 형식(YOLO)
void main() {
  final jpeg = File('assets/test_frames/scene_01.jpg').readAsBytesSync();

  HazardReport report(List<Map<String, Object>> equipment) =>
      HazardReport.fromJson(
          {'summary': '기계실', 'hazards': [], 'equipment': equipment},
          10,
          const Size(1080, 1440));

  test('설비: 모르는 종류·위치 없는 박스는 버리고, 저장했다 다시 읽어도 같음', () {
    final r = report([
      {
        'label': 'valve',
        'box_2d': [100, 200, 300, 400]
      },
      {
        'label': 'toaster',
        'box_2d': [100, 200, 300, 400]
      },
      {
        'label': 'pipe',
        'box_2d': [0, 0, 0, 0]
      },
      {'label': 'pump'},
    ]);
    expect(r.equipment.map((e) => e.label), ['valve']);
    expect(r.equipment.single.box, const Rect.fromLTRB(0.2, 0.1, 0.4, 0.3));
    expect(r.equipment.single.name, '밸브');

    final again = HazardReport.fromJson(r.toJson(), 0, const Size(1080, 1440));
    expect(again.equipment.single.box, r.equipment.single.box);
    // 설비가 없으면 저장 json에 키도 안 생김(예전 기록과 같은 모양)
    expect(report([]).toJson().containsKey('equipment'), isFalse);
  });

  test('Gemini: 켰을 때만 설비 프롬프트·스키마를 보내고 응답의 설비를 읽음', () async {
    final bodies = <Map<String, dynamic>>[];
    final client = MockClient((req) async {
      bodies.add(jsonDecode(req.body) as Map<String, dynamic>);
      final answer = jsonEncode({
        'summary': '배관',
        'hazards': [],
        'equipment': [
          {
            'label': 'pipe',
            'box_2d': [500, 0, 600, 1000]
          },
          {
            'label': 'gauge',
            'box_2d': [100, 100, 200, 200]
          },
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
    final a = GeminiHazardAnalyzer(client: client, apiKey: 'k', model: 'm');

    final on = await a.analyze(jpeg, equipment: true);
    await a.analyze(jpeg);

    String prompt(Map<String, dynamic> b) =>
        b['contents'][0]['parts'][0]['text'] as String;
    Map props(Map<String, dynamic> b) =>
        b['generationConfig']['responseSchema']['properties'] as Map;
    expect(prompt(bodies[0]), contains('electrical_panel(분전반·제어반)'));
    expect(
        props(bodies[0])['equipment']['items']['properties']['label']['enum'],
        Equipment.labels.keys.toList());
    expect(prompt(bodies[1]), isNot(contains('equipment')));
    expect(props(bodies[1]).containsKey('equipment'), isFalse);
    expect(on.equipment.map((e) => e.label), ['pipe', 'gauge']);
  });

  test('YOLO 라벨: 클래스 번호와 중심·크기(0..1), 사진 밖은 잘라냄', () {
    final lines = EquipmentDataset.yoloLines(const [
      Equipment('valve', Rect.fromLTRB(0.2, 0.1, 0.4, 0.3)),
      Equipment('cable_tray', Rect.fromLTRB(0.5, 0.5, 1.5, 0.7)),
    ]);
    expect(lines[0], '0 0.300000 0.200000 0.200000 0.200000');
    expect(lines[1].split(' ').first,
        '${EquipmentDataset.classes.indexOf('cable_tray')}');
    expect(lines[1].split(' ')[3], '1.000000');
  });

  test('설비 탐지기 결과: [l,t,r,b,점수,클래스] → 0..1 박스와 한국어 이름', () {
    final d = EquipmentDetector.parse([
      0.1, 0.2, 0.5, 0.6, 0.8, 4, //
      -0.1, 0.9, 0.3, 1.2, 0.4, 0, //
      0.5, 0.5, 0.6, 0.6, 0.3, 99, // 모르는 클래스 번호
      0.1, 0.1, // 잘린 꼬리는 버림
    ]);
    expect(d.length, 3);
    expect(d[0].box, const Rect.fromLTRB(0.1, 0.2, 0.5, 0.6));
    expect(d[0].label, '분전반·제어반');
    expect(d[0].confidence, 0.8);
    expect(d[0].trackingId, isNull);
    expect(d[1].box, const Rect.fromLTRB(0, 0.9, 0.3, 1));
    expect(d[1].label, '밸브');
    expect(d[2].label, '');
  });

  test('저장: 사진·라벨·클래스·기록 한 줄, 설비가 없으면 저장 안 함', () async {
    final tmp = await Directory.systemTemp.createTemp('dataset');
    addTearDown(() => tmp.delete(recursive: true));
    final ds = EquipmentDataset(tmp);
    final at = DateTime(2026, 11, 3, 16, 30, 5, 123);

    expect(await ds.add(jpeg, report([]), at: at), isNull);
    expect(tmp.listSync(), isEmpty);

    final img = await ds.add(
        jpeg,
        report([
          {
            'label': 'pump',
            'box_2d': [100, 200, 300, 400]
          }
        ]),
        place: 'B2 기계실',
        at: at);
    expect(img!.readAsBytesSync(), jpeg);
    final name = img.uri.pathSegments.last.replaceAll('.jpg', '');
    expect(File('${tmp.path}/labels/$name.txt').readAsStringSync(),
        '2 0.300000 0.200000 0.200000 0.200000\n');
    expect(File('${tmp.path}/classes.txt').readAsLinesSync(),
        EquipmentDataset.classes);
    final rec =
        jsonDecode(File('${tmp.path}/samples.jsonl').readAsLinesSync().single)
            as Map;
    expect(rec['image'], 'images/$name.jpg');
    expect(rec['place'], 'B2 기계실');
    expect(rec['equipment'][0]['label'], 'pump');
  });
}
