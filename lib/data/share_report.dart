import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/painting.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../analysis/hazard.dart';
import '../ui/box_painter.dart';
import 'inspection_repository.dart';
import 'models.dart';
import 'report_csv.dart';
import 'report_text.dart';

/// 사진 위에 위험 박스·이름을 그려 PNG로(화면에서 보던 그대로)
Future<Uint8List> annotatedPhoto(File photo, HazardReport report) async {
  final codec = await ui.instantiateImageCodec(await photo.readAsBytes());
  final img = (await codec.getNextFrame()).image;
  final size = Size(img.width.toDouble(), img.height.toDouble());
  final rec = ui.PictureRecorder();
  final canvas = Canvas(rec)..drawImage(img, Offset.zero, Paint());
  // 캔버스 = 사진 크기라 박스 좌표가 그대로 맞음
  HazardBoxPainter(report).paint(canvas, size);
  final out = await rec.endRecording().toImage(img.width, img.height);
  final png = await out.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  out.dispose();
  return png!.buffer.asUint8List();
}

/// 점검 요약 + 위험 표시한 사진들을 메신저·메일로 공유(안드로이드 공유 시트)
Future<void> shareInspection(InspectionRepository repo, Inspection i) async {
  final tmp = await getTemporaryDirectory();
  final dir = Directory('${tmp.path}/share_${i.id}');
  if (await dir.exists()) await dir.delete(recursive: true);
  await dir.create(recursive: true);
  final files = <XFile>[];
  var n = 1;
  for (final f in i.findings) {
    final photo = repo.photoFile(i, f);
    if (!await photo.exists()) continue;
    final png = await annotatedPhoto(photo, f.report);
    final out = File('${dir.path}/${n.toString().padLeft(2, '0')}_${f.id}.png');
    await out.writeAsBytes(png, flush: true);
    files.add(XFile(out.path, mimeType: 'image/png'));
    n++;
  }
  await SharePlus.instance.share(ShareParams(
    subject: '[시설 안전점검] ${i.location}',
    text: inspectionReportText(i),
    files: files.isEmpty ? null : files,
  ));
}

/// 발견사항을 CSV(엑셀)로 내보내 공유
Future<void> shareInspectionCsv(Inspection i) async {
  final tmp = await getTemporaryDirectory();
  final d = i.startedAt;
  final safe = i.location.replaceAll(RegExp(r'[\/:*?"<>|\s]+'), '_');
  final file = File(
      '${tmp.path}/점검_${safe}_${d.year}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}.csv');
  await file.writeAsString(inspectionCsv(i), flush: true);
  await SharePlus.instance.share(ShareParams(
    subject: '[시설 안전점검] ${i.location} (CSV)',
    files: [XFile(file.path, mimeType: 'text/csv')],
  ));
}
