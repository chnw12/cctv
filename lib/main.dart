import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'analysis/default_analyzer.dart';
import 'app/app.dart';
import 'core/app_log.dart';
import 'data/app_settings.dart';
import 'data/inspection_repository.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

  // 설정·점검 기록은 기기 안 앱 전용 폴더에(인터넷 없어도 동작)
  final docs = await getApplicationDocumentsDirectory();
  // 앱 기록(오류·성능 줄)은 케이블로 꺼낼 수 있는 외부 저장소에(없으면 앱 폴더)
  try {
    await AppLog.init(await getExternalStorageDirectory() ?? docs);
  } catch (e) {
    debugPrint('앱 기록 시작 못 함: $e');
  }
  final settings = AppSettings(File('${docs.path}/settings.json'));
  final repo = InspectionRepository(docs);
  await Future.wait([settings.load(), repo.load()]);

  runApp(FacilityApp(
    settings: settings,
    repo: repo,
    analyzer: createDefaultAnalyzer(),
  ));
}
