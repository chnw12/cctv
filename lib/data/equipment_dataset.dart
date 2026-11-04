import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import '../analysis/hazard.dart';

/// AI 점검 때 Gemini가 짚은 설비 박스를 사진과 함께 YOLO 형식으로 쌓음(설비 전용 탐지기 학습용).
///   <dir>/images/<이름>.jpg
///   <dir>/labels/<이름>.txt   한 줄에 "클래스번호 cx cy w h"(0..1, YOLO 형식)
///   <dir>/classes.txt         클래스 번호 순서(= Equipment.labels 순서)
///   <dir>/samples.jsonl       장소·시각·요약·원본 박스(검수·출처 확인용)
/// 앱 외부 저장소에 두어 adb pull로 PC에 꺼냄. 사람이 일부를 검수한 뒤 학습에 씁니다.
class EquipmentDataset {
  EquipmentDataset(this.dir);
  final Directory dir;

  static final classes = Equipment.labels.keys.toList();

  /// YOLO 라벨 줄(소수 6자리, 사진 밖으로 나간 부분은 잘라냄)
  static List<String> yoloLines(List<Equipment> equipment) => [
        for (final e in equipment)
          if (classes.indexOf(e.label) case final c when c >= 0)
            [
              c,
              for (final v in [
                (e.box.left + e.box.right) / 2,
                (e.box.top + e.box.bottom) / 2,
                e.box.width,
                e.box.height,
              ])
                v.clamp(0.0, 1.0).toStringAsFixed(6),
            ].join(' ')
      ];

  /// 설비가 하나도 없으면 저장하지 않음(AI가 못 본 사진이 "설비 없음" 정답으로 들어가지 않게).
  /// 저장한 사진 파일, 안 했으면 null
  Future<File?> add(Uint8List jpeg, HazardReport report,
      {String? place, DateTime? at}) async {
    final lines = yoloLines(report.equipment);
    if (lines.isEmpty) return null;
    final t = at ?? DateTime.now();
    final name = t.toIso8601String().replaceAll(RegExp(r'[:.]'), '');
    final image = File('${dir.path}/images/$name.jpg');
    await image.parent.create(recursive: true);
    await Directory('${dir.path}/labels').create(recursive: true);
    await image.writeAsBytes(jpeg, flush: true);
    await File('${dir.path}/labels/$name.txt')
        .writeAsString('${lines.join('\n')}\n', flush: true);
    await File('${dir.path}/classes.txt')
        .writeAsString('${classes.join('\n')}\n', flush: true);
    await File('${dir.path}/samples.jsonl').writeAsString(
        '${jsonEncode({
              'image': 'images/$name.jpg',
              'at': t.toIso8601String(),
              if (place != null && place.isNotEmpty) 'place': place,
              'w': report.imageSize.width.round(),
              'h': report.imageSize.height.round(),
              'summary': report.summary,
              'equipment': [for (final e in report.equipment) e.toJson()],
            })}\n',
        mode: FileMode.append,
        flush: true);
    return image;
  }
}
