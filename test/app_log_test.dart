import 'dart:io';
import 'package:facility_camera/core/app_log.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 앱 기록: 기록 줄·오류·지난 종료 이유가 날짜별 파일에 쌓이는지
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const ch = MethodChannel('facility_camera/app_info');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory tmp;
  var exits = <Map<String, Object?>>[];

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('fc_log_');
    exits = [];
    messenger.setMockMethodCallHandler(
        ch,
        (call) async => {
              'model': 'samsung SM-F766N',
              'android': '17',
              'sdk': 37,
              'version': '0.1.0',
              'build': 2001,
              'exits': exits,
            });
  });
  tearDown(() {
    AppLog.reset();
    messenger.setMockMethodCallHandler(ch, null);
    tmp.deleteSync(recursive: true);
  });

  String today() {
    final t = DateTime.now();
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
  }

  Future<String> read() async {
    await Future<void>.delayed(
        const Duration(milliseconds: 20)); // 기기 정보는 비동기로 적힘
    AppLog.flush();
    return File('${tmp.path}/app_logs/${today()}.log').readAsStringSync();
  }

  test('기록 줄(debugPrint)·오류(+스택)·기기 정보가 오늘 파일에', () async {
    await AppLog.init(tmp, hookErrors: false);
    debugPrint('PERF source=camera in=15 proc=14');
    AppLog.error('기록 저장 실패', StateError('디스크 가득'), StackTrace.current);
    final s = await read();
    expect(s, contains('I === 앱 시작'));
    expect(s, contains('I PERF source=camera in=15 proc=14'));
    expect(s, contains('E 기록 저장 실패: Bad state: 디스크 가득'));
    expect(s, contains('app_log_test.dart')); // 스택 위치
    expect(
        s, contains('기기 samsung SM-F766N · 안드로이드 17(SDK 37) · 앱 0.1.0(2001)'));
  });

  test('지난 종료 이유: 충돌은 오류(E)로, 이미 적은 건 다음 시작 때 다시 안 적음', () async {
    final t = DateTime(2026, 11, 4, 10, 12).millisecondsSinceEpoch;
    exits = [
      {'time': t, 'reason': '충돌(네이티브)', 'desc': 'signal 11', 'rssKb': 512000},
      {
        'time': t - 60000,
        'reason': '사용자가 종료(최근 앱에서 밀기 등)',
        'desc': '',
        'rssKb': 0
      },
    ];
    await AppLog.init(tmp, hookErrors: false);
    final s = await read();
    expect(
        s,
        contains(
            'E 지난 종료 2026-11-04 10:12:00.000: 충돌(네이티브) signal 11 (메모리 500MB)'));
    expect(s, contains('I 지난 종료 2026-11-04 10:11:00.000: 사용자가 종료'));

    AppLog.reset();
    await AppLog.init(tmp, hookErrors: false);
    final again = await read();
    expect('지난 종료 2026-11-04 10:12'.allMatches(again).length, 1);
  });

  test('하루 5MB를 넘으면 오류 줄만, 14일 지난 파일은 지움', () async {
    final dir = Directory('${tmp.path}/app_logs')..createSync();
    File('${dir.path}/${today()}.log')
        .writeAsBytesSync(Uint8List(AppLog.maxBytesPerDay + 1));
    File('${dir.path}/2020-01-01.log').writeAsStringSync('old');
    await AppLog.init(tmp, hookErrors: false);
    debugPrint('PERF 넘침');
    AppLog.error('카메라 열기 실패', 'CameraException');
    final s = await read();
    expect(s, isNot(contains('PERF 넘침')));
    expect(s, contains('E 카메라 열기 실패: CameraException'));
    expect(File('${dir.path}/2020-01-01.log').existsSync(), isFalse);
    expect((await AppLog.files()).single.path, endsWith('${today()}.log'));
  });
}
