import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 앱 기록: 쓰는 동안 나오는 기록 줄(debugPrint — PERF 성능 줄 포함)·오류(+스택)·지난번 종료 이유를
/// 날짜별 파일로 폰에 쌓음. 현장에서 생긴 문제를 나중에(다시 만들 때) 근거로 보려고.
///   <외부 저장소>/app_logs/2026-11-04.log   한 줄 = "10:15:30.123 I 내용" (E = 오류)
/// 케이블 없이 설정 → 개발자 → 앱 기록에서 보고 공유. 케이블이 있으면 adb pull files/app_logs
/// 하루 5MB까지(넘으면 오류 줄만), 14일 지나면 지움. API 키 같은 비밀은 원래 기록 줄에 안 씀
class AppLog {
  AppLog._();

  static const maxBytesPerDay = 5 * 1024 * 1024;
  static const keepDays = 14;
  static const _info = MethodChannel('facility_camera/app_info');

  static Directory? _dir;
  static RandomAccessFile? _raf;
  static String? _day;
  static int _bytes = 0;
  static DebugPrintCallback? _origPrint;
  static bool _writing = false;

  static Directory? get dir => _dir;

  /// 기록 폴더를 정하고 debugPrint·오류 처리기를 연결. 앱 시작 때 한 번
  static Future<void> init(Directory dir, {bool hookErrors = true}) async {
    _dir = Directory('${dir.path}/app_logs');
    await _dir!.create(recursive: true);
    await _prune();
    _origPrint ??= debugPrint;
    debugPrint = (String? m, {int? wrapWidth}) {
      _origPrint!(m, wrapWidth: wrapWidth);
      if (m != null) _write('I', m);
    };
    if (hookErrors) {
      final prev = FlutterError.onError;
      FlutterError.onError = (d) {
        error('화면 오류', d.exception, d.stack);
        prev?.call(d);
      };
      PlatformDispatcher.instance.onError = (e, st) {
        error('처리 안 된 오류', e, st);
        return false; // 원래대로(콘솔 출력) 계속
      };
    }
    _write('I', '=== 앱 시작 ${kReleaseMode ? '릴리스' : '디버그'} ===');
    unawaited(_startInfo());
  }

  /// 기기·버전, 그리고 지난번 기록 뒤에 새로 생긴 종료 이유(충돌·메모리 부족 등)
  static Future<void> _startInfo() async {
    try {
      final m = await _info.invokeMapMethod<String, Object?>('startInfo');
      if (m == null) return;
      _write(
          'I',
          '기기 ${m['model']} · 안드로이드 ${m['android']}(SDK ${m['sdk']}) · '
              '앱 ${m['version']}(${m['build']})');
      final seenFile = File('${_dir!.path}/.last_exit');
      final seen = int.tryParse(seenFile.existsSync()
              ? seenFile.readAsStringSync().trim()
              : '') ??
          0;
      var newest = seen;
      final exits = (m['exits'] as List?) ?? const [];
      for (final e in exits.reversed) {
        final x = (e as Map).cast<String, Object?>();
        final t = (x['time'] as num).toInt();
        if (t <= seen) continue;
        newest = t > newest ? t : newest;
        final when = DateTime.fromMillisecondsSinceEpoch(t);
        final bad = '${x['reason']}'.startsWith('충돌') ||
            '${x['reason']}'.startsWith('응답') ||
            '${x['reason']}'.startsWith('메모리');
        _write(bad ? 'E' : 'I',
            '지난 종료 ${_stamp(when)}: ${x['reason']} ${x['desc']} (메모리 ${((x['rssKb'] as num?) ?? 0) ~/ 1024}MB)');
      }
      if (newest > seen) seenFile.writeAsStringSync('$newest');
    } catch (e) {
      _write('I', '기기 정보 못 읽음: $e'); // 테스트·안드로이드 아닌 환경
    }
  }

  /// 오류 한 건(+스택 앞부분). 바로 디스크에 씀(곧 앱이 죽어도 남게)
  static void error(String where, Object e, [StackTrace? st]) {
    final stack = st == null
        ? ''
        : '\n${st.toString().split('\n').where((l) => l.trim().isNotEmpty).take(12).join('\n')}';
    _write('E', '$where: $e$stack');
  }

  static void _write(String level, String msg) {
    final d = _dir;
    if (d == null || _writing) return;
    _writing = true; // 쓰다가 난 오류가 다시 기록으로 돌아오는 것 막기
    try {
      final now = DateTime.now();
      final day = _date(now);
      if (day != _day) {
        _raf?.closeSync();
        final f = File('${d.path}/$day.log');
        _raf = f.openSync(mode: FileMode.append);
        _bytes = f.lengthSync();
        _day = day;
      }
      if (level != 'E' && _bytes > maxBytesPerDay) return;
      final line = '${_stamp(now).substring(11)} $level $msg\n';
      _raf!.writeStringSync(line);
      _bytes += line.length;
      if (level == 'E') _raf!.flushSync();
    } catch (_) {
      // 기록 실패는 앱 동작에 영향 주지 않음
    } finally {
      _writing = false;
    }
  }

  static String _date(DateTime t) =>
      '${t.year}-${_pad2(t.month)}-${_pad2(t.day)}';
  static String _stamp(DateTime t) =>
      '${_date(t)} ${_pad2(t.hour)}:${_pad2(t.minute)}:${_pad2(t.second)}.${t.millisecond.toString().padLeft(3, '0')}';
  static String _pad2(int v) => v.toString().padLeft(2, '0');

  static Future<void> _prune() async {
    final cut = DateTime.now().subtract(const Duration(days: keepDays));
    await for (final f in _dir!.list()) {
      if (f is File && f.path.endsWith('.log')) {
        final name = f.uri.pathSegments.last.replaceAll('.log', '');
        final d = DateTime.tryParse(name);
        if (d != null && d.isBefore(cut)) await f.delete();
      }
    }
  }

  /// 기록 파일들(최근 날짜부터)
  static Future<List<File>> files() async {
    final d = _dir;
    if (d == null || !await d.exists()) return const [];
    final out = [
      await for (final f in d.list())
        if (f is File && f.path.endsWith('.log')) f
    ]..sort((a, b) => b.path.compareTo(a.path));
    return out;
  }

  /// 디스크에 다 쓰기(공유 전에)
  static void flush() {
    try {
      _raf?.flushSync();
    } catch (_) {}
  }

  /// 테스트용: 원래 debugPrint로 되돌리고 닫음
  @visibleForTesting
  static void reset() {
    if (_origPrint != null) debugPrint = _origPrint!;
    _origPrint = null;
    _raf?.closeSync();
    _raf = null;
    _dir = null;
    _day = null;
    _bytes = 0;
  }
}
