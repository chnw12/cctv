import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Size;
import 'package:flutter/foundation.dart';
import '../analysis/hazard.dart';
import '../core/jpeg.dart';
import 'models.dart';

/// 점검 기록 저장소. 기기 안에만 저장(인터넷 없어도 동작):
///   <root>/inspections/<점검ID>/inspection.json
///   <root>/inspections/<점검ID>/<발견ID>.jpg
/// 바뀔 때마다 그 점검의 json 하나만 다시 씁니다(임시 파일에 쓰고 이름 바꾸기 → 중간에 꺼져도 안 깨짐).
class InspectionRepository extends ChangeNotifier {
  InspectionRepository(this.root);

  final Directory root;
  final _items = <Inspection>[];

  /// 최근 시작한 순
  List<Inspection> get inspections => List.unmodifiable(_items);

  Directory _dirOf(String inspectionId) =>
      Directory('${root.path}/inspections/$inspectionId');

  File photoFile(Inspection i, Finding f) =>
      File('${_dirOf(i.id).path}/${f.photo}');

  /// 위험을 완료할 때 찍은 조치 후 사진(없으면 null)
  File? afterPhotoFile(Inspection i, Hazard h) => h.afterPhoto == null
      ? null
      : File('${_dirOf(i.id).path}/${h.afterPhoto}');

  Inspection? byId(String id) {
    for (final i in _items) {
      if (i.id == id) return i;
    }
    return null;
  }

  Future<void> load() async {
    _items.clear();
    final base = Directory('${root.path}/inspections');
    if (await base.exists()) {
      await for (final d in base.list()) {
        if (d is! Directory) continue;
        final f = File('${d.path}/inspection.json');
        if (!await f.exists()) continue;
        try {
          _items.add(Inspection.fromJson(
              jsonDecode(await f.readAsString()) as Map<String, dynamic>));
        } catch (e) {
          debugPrint('점검 기록 읽기 실패(${d.path}): $e'); // 깨진 기록 하나 때문에 전체가 안 열리지 않게
        }
      }
    }
    _sort();
    notifyListeners();
  }

  Future<Inspection> create(String location) async {
    final now = DateTime.now();
    final i =
        Inspection(id: _newId(now), location: location.trim(), startedAt: now);
    await _dirOf(i.id).create(recursive: true);
    _items.add(i);
    _sort();
    await _save(i);
    return i;
  }

  /// 사진과 AI 결과를 발견사항으로 저장
  Future<Finding> addFinding(Inspection i, Uint8List jpeg, HazardReport report,
      FindingSource source) async {
    final now = DateTime.now();
    final id = _newId(now);
    final size = report.imageSize == Size.zero
        ? await encodedImageSize(jpeg)
        : report.imageSize;
    final f = Finding(
      id: id,
      createdAt: now,
      photo: '$id.jpg',
      imageSize: size,
      report: report,
      source: source,
    );
    await _dirOf(i.id).create(recursive: true);
    await photoFile(i, f).writeAsBytes(jpeg, flush: true);
    i.findings.add(f);
    await _save(i);
    return f;
  }

  /// resolved: 기록 전체 조치 완료 표시. 끄면 위험별로 "완료"한 것도 미조치로 되돌림
  /// (무시한 위험은 AI 오탐 기록이라 그대로)
  Future<void> updateFinding(Inspection i, Finding f,
      {bool? resolved, String? memo}) async {
    if (resolved != null) {
      f.resolved = resolved;
      if (!resolved) {
        for (final h in f.report.hazards) {
          if (h.status == HazardStatus.resolved) await _reopen(i, h);
        }
      }
    }
    if (memo != null) f.memo = memo;
    await _save(i);
  }

  /// 위험 하나의 처리 상태(카메라 화면의 무시·완료, 되돌리기, 기록 화면).
  /// 완료 때 사진을 주면 조치 후 사진으로 같이 저장. open으로 되돌리면 그 사진은 지움
  Future<void> setHazardStatus(
      Inspection i, Finding f, int index, HazardStatus status,
      {required String by, Uint8List? afterJpeg}) async {
    final h = f.report.hazards[index];
    if (status == HazardStatus.open) {
      await _reopen(i, h);
    } else {
      String? after;
      if (afterJpeg != null) {
        after = '${f.id}_after$index.jpg';
        await _dirOf(i.id).create(recursive: true);
        await File('${_dirOf(i.id).path}/$after')
            .writeAsBytes(afterJpeg, flush: true);
      } else {
        await _deleteAfterPhoto(i, h);
      }
      h.setStatus(status, by: by, afterPhoto: after);
    }
    await _save(i);
  }

  Future<void> _reopen(Inspection i, Hazard h) async {
    await _deleteAfterPhoto(i, h);
    h.setStatus(HazardStatus.open);
  }

  Future<void> _deleteAfterPhoto(Inspection i, Hazard h) async {
    final file = afterPhotoFile(i, h);
    if (file != null && await file.exists()) await file.delete();
  }

  /// 나중에 AI로 분석한 결과로 바꿈(사진 크기는 그대로)
  Future<void> setReport(Inspection i, Finding f, HazardReport report) async {
    f.report = report;
    await _save(i);
  }

  Future<void> deleteFinding(Inspection i, Finding f) async {
    i.findings.remove(f);
    final file = photoFile(i, f);
    if (await file.exists()) await file.delete();
    for (final h in f.report.hazards) {
      await _deleteAfterPhoto(i, h);
    }
    await _save(i);
  }

  Future<void> rename(Inspection i, String location) async {
    i.location = location.trim();
    await _save(i);
  }

  Future<void> finish(Inspection i) async {
    i.endedAt ??= DateTime.now();
    await _save(i);
  }

  Future<void> delete(Inspection i) async {
    _items.remove(i);
    final d = _dirOf(i.id);
    if (await d.exists()) await d.delete(recursive: true);
    notifyListeners();
  }

  Future<void> _save(Inspection i) async {
    final dir = _dirOf(i.id);
    await dir.create(recursive: true);
    final tmp = File('${dir.path}/inspection.json.tmp');
    await tmp.writeAsString(jsonEncode(i.toJson()), flush: true);
    await tmp.rename('${dir.path}/inspection.json');
    notifyListeners();
  }

  void _sort() => _items.sort((a, b) => b.startedAt.compareTo(a.startedAt));

  int _seq = 0;
  String _newId(DateTime t) =>
      '${t.millisecondsSinceEpoch.toRadixString(36)}${(_seq++ % 1296).toRadixString(36).padLeft(2, '0')}';
}
