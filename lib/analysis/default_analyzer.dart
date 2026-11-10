import 'claude_hazard_analyzer.dart';
import 'fake_hazard_analyzer.dart';
import 'gemini_hazard_analyzer.dart';
import 'hazard_analyzer.dart';

/// 앱이 쓸 AI를 빌드할 때 정함(--dart-define).
///   FAKE_AI=true        가짜 AI(네트워크 안 씀, 에뮬레이터·화면 캡처용)
///   AI_PROVIDER=claude  Claude(기본 모델 claude-sonnet-5-5, 키는 .env의 CLAUDE_EVAL_KEY 또는 CLAUDE_API_KEY)
///   AI_PROVIDER=gemini  Gemini(키는 secrets.json의 GEMINI_API_KEY)
///   비우면              Claude 키가 있으면 Claude, 없고 Gemini 키만 있으면 Gemini
/// 시연용 빌드: flutter build apk --release --dart-define-from-file=secrets.json --dart-define-from-file=.env
/// 지금 어느 AI인지는 홈 화면 AI 카드·설정의 AI 점검 칸에 나옴
HazardAnalyzer createDefaultAnalyzer() {
  if (const bool.fromEnvironment('FAKE_AI')) return FakeHazardAnalyzer();
  final claude = ClaudeHazardAnalyzer(), gemini = GeminiHazardAnalyzer();
  return pickAnalyzer(const String.fromEnvironment('AI_PROVIDER'),
      claude: claude, gemini: gemini);
}

/// [provider]가 claude·gemini면 그대로, 아니면 쓸 수 있는 쪽(둘 다 되면 Claude, 둘 다 안 되면 Claude의 안내)
HazardAnalyzer pickAnalyzer(String provider,
        {required HazardAnalyzer claude, required HazardAnalyzer gemini}) =>
    switch (provider.trim().toLowerCase()) {
      'claude' => claude,
      'gemini' => gemini,
      _ => claude.unavailableReason == null || gemini.unavailableReason != null
          ? claude
          : gemini,
    };
