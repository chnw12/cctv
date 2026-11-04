import 'package:flutter/material.dart';
import '../analysis/hazard_analyzer.dart';
import '../data/app_settings.dart';
import '../data/inspection_repository.dart';
import '../screens/home_screen.dart';

/// 화면이 다른 화면에 가려지고 다시 보이는 것을 알고 싶을 때(점검 화면의 볼륨 키 등)
final appRouteObserver = RouteObserver<PageRoute<dynamic>>();

/// 앱 전역 객체(설정·점검 기록·AI)를 화면들에 건넵니다. 값이 바뀌면 각 화면이
/// ListenableBuilder로 직접 구독하므로 이 위젯 자체는 다시 그릴 일이 없습니다.
class AppScope extends InheritedWidget {
  const AppScope({
    super.key,
    required this.settings,
    required this.repo,
    required this.analyzer,
    required super.child,
  });

  final AppSettings settings;
  final InspectionRepository repo;
  final HazardAnalyzer analyzer;

  static AppScope of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!;

  @override
  bool updateShouldNotify(AppScope old) => false;
}

class FacilityApp extends StatelessWidget {
  const FacilityApp({
    super.key,
    required this.settings,
    required this.repo,
    required this.analyzer,
  });

  final AppSettings settings;
  final InspectionRepository repo;
  final HazardAnalyzer analyzer;

  @override
  Widget build(BuildContext context) {
    return AppScope(
      settings: settings,
      repo: repo,
      analyzer: analyzer,
      child: MaterialApp(
        title: '시설기사 안전카메라',
        debugShowCheckedModeBanner: false,
        // 기계실·전기실 현장: 어두운 화면 + 큰 버튼
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          colorSchemeSeed: Colors.amber,
        ),
        navigatorObservers: [appRouteObserver],
        home: const HomeScreen(),
      ),
    );
  }
}
