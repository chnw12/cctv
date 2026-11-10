import 'package:camera/camera.dart' show ResolutionPreset;
import 'package:flutter/material.dart';
import '../app/app.dart';
import '../data/app_settings.dart';
import '../ui/camera_test_screen.dart';
import 'app_log_screen.dart';
import '../ui/recording_controls.dart';

/// 설정: 카메라·AI·개발자 도구. 바꾸면 바로 저장되고 카메라는 알아서 다시 열립니다.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  static String presetLabel(ResolutionPreset p) => switch (p) {
        ResolutionPreset.low => '낮음 (240p)',
        ResolutionPreset.medium => '보통 (480p)',
        ResolutionPreset.high => '높음 (720p, 권장)',
        ResolutionPreset.veryHigh => '매우 높음 (1080p)',
        ResolutionPreset.ultraHigh => '최고 (4K)',
        ResolutionPreset.max => '최대',
      };

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final s = scope.settings;
    final ai = scope.analyzer;
    return Scaffold(
      appBar: AppBar(title: const Text('설정')),
      body: ListenableBuilder(
        listenable: s,
        builder: (context, _) => ListView(
          children: [
            const _Header('카메라'),
            ListTile(
              title: const Text('해상도'),
              subtitle: const Text('높을수록 AI 사진이 선명, 실시간 탐지는 느려짐'),
              trailing: DropdownButton<ResolutionPreset>(
                value: s.preset,
                items: [
                  for (final p in AppSettings.presetChoices)
                    DropdownMenuItem(value: p, child: Text(presetLabel(p))),
                ],
                onChanged: (p) => s.update((s) => s.preset = p!),
              ),
            ),
            ListTile(
              title: const Text('카메라 FPS 상한'),
              subtitle: const Text('처리 속도 근처로 낮추면 탐지가 빨라짐(권장 15)'),
              trailing: DropdownButton<int>(
                value: s.cameraFps,
                items: [
                  for (final f in AppSettings.fpsChoices)
                    DropdownMenuItem(
                        value: f, child: Text(f == 0 ? '제한 없음' : '$f')),
                ],
                onChanged: (f) => s.update((s) => s.cameraFps = f!),
              ),
            ),
            SwitchListTile(
              title: const Text('자이로 보정'),
              subtitle: const Text('폰을 돌릴 때 물체 추적이 끊기지 않게(자율주행 IMU 보정 방식)'),
              value: s.gyro,
              onChanged: (v) => s.update((s) => s.gyro = v),
            ),
            SwitchListTile(
              title: const Text('어두우면 노출 자동 보정'),
              subtitle: const Text('어두운 기계실에서 화면·AI 사진을 밝게(손전등 없이도)'),
              value: s.autoExposure,
              onChanged: (v) => s.update((s) => s.autoExposure = v),
            ),
            SwitchListTile(
              title: const Text('손가락으로 위험 박스 누르기'),
              subtitle: const Text(
                  '카메라에 손을 비추고 검지 끝을 위험 박스에 대면 무시·완료 버튼, 버튼 위에 1초 두면 선택(화면 탭도 됨)'),
              value: s.handControl,
              onChanged: (v) => s.update((s) => s.handControl = v),
            ),
            SwitchListTile(
              title: const Text('실시간 탐지 박스 표시'),
              value: s.showDetections,
              onChanged: (v) => s.update((s) => s.showDetections = v),
            ),
            ListTile(
              title: const Text('안 쓰면 카메라 멈춤'),
              subtitle: const Text('화면을 만지지 않으면 카메라를 멈춰 배터리 절약(탭하면 다시 시작)'),
              trailing: DropdownButton<int>(
                value: s.idlePauseMin,
                items: [
                  for (final m in AppSettings.idleChoices)
                    DropdownMenuItem(
                        value: m, child: Text(m == 0 ? '안 멈춤' : '$m분')),
                ],
                onChanged: (m) => s.update((s) => s.idlePauseMin = m!),
              ),
            ),
            const _Header('AI 점검'),
            ListTile(
              leading: Icon(
                  ai.unavailableReason == null
                      ? Icons.cloud_done
                      : Icons.cloud_off,
                  color: ai.unavailableReason == null
                      ? Colors.greenAccent
                      : Colors.orangeAccent),
              title: Text(ai.description),
              subtitle: Text(ai.unavailableReason ??
                  '모델·키는 빌드할 때 정합니다(.env·secrets.json, 앱 다시 빌드 필요)'),
            ),
            SwitchListTile(
              title: const Text('자동 점검을 켠 채로 시작'),
              subtitle: const Text('새 물체가 나타나면 AI 점검(점검 화면에서 바로 끄고 켤 수 있음)'),
              value: s.autoAi,
              onChanged: (v) => s.update((s) => s.autoAi = v),
            ),
            ListTile(
              title: const Text('자동 점검 최소 간격'),
              subtitle: Text('${s.autoAiCooldownSec}초 (AI 사용량·비용 조절)'),
              trailing: SizedBox(
                width: 160,
                child: Slider(
                  min: 5,
                  max: 60,
                  divisions: 11,
                  value: s.autoAiCooldownSec.toDouble().clamp(5, 60),
                  label: '${s.autoAiCooldownSec}초',
                  onChanged: (v) =>
                      s.update((s) => s.autoAiCooldownSec = v.round()),
                ),
              ),
            ),
            SwitchListTile(
              title: const Text('자동 점검에서 위험 발견 시 바로 저장'),
              value: s.autoSaveHazards,
              onChanged: (v) => s.update((s) => s.autoSaveHazards = v),
            ),
            const _Header('개발자'),
            ListTile(
              leading: const Icon(Icons.receipt_long),
              title: const Text('앱 기록(오류·성능)'),
              subtitle:
                  const Text('쓰는 동안 나온 오류·성능 줄과 앱이 꺼진 이유가 날짜별로 쌓임. 보기·공유'),
              onTap: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const AppLogScreen())),
            ),
            SwitchListTile(
              title: const Text('분석 로그 기록'),
              subtitle: const Text(
                  '카메라 화면을 열 때마다 원본 탐지·자이로를 파일로 남김(PC에서 추적기를 다시 돌려 보는 용도, 30분에 약 20MB)'),
              value: s.analysisLog,
              onChanged: (v) => s.update((s) => s.analysisLog = v),
            ),
            SwitchListTile(
              title: const Text('탐지기 학습 데이터 모으기'),
              subtitle: const Text('AI 점검 때 설비(밸브·배관·분전반 등) 위치도 받아 사진과 함께 저장. '
                  '설비 전용 탐지기 학습용이며 AI 응답이 조금 느려질 수 있음'),
              value: s.collectEquipment,
              onChanged: (v) => s.update((s) => s.collectEquipment = v),
            ),
            SwitchListTile(
              title: const Text('설비 탐지기 시험'),
              subtitle:
                  const Text('실시간 탐지를 ML Kit 대신 설비 전용 모델(밸브·배관·분전반 등 10종)로. '
                      '학습 없이 이름으로 찾는 YOLOE 시험판이라 시연·비교용(배포 금지)'),
              value: s.equipmentDetector,
              onChanged: (v) => s.update((s) => s.equipmentDetector = v),
            ),
            SwitchListTile(
              title: const Text('녹화 버튼 보이기'),
              subtitle: const Text(
                  '카메라 화면 왼쪽에 녹화 버튼. 카메라 원본 화면과 자이로를 남겨, 나중에 같은 장면으로 새 기능을 '
                  '시험함(1분에 약 60MB, 10분이면 자동으로 멈춤). 시연 영상은 폰의 "화면 녹화" 기능으로'),
              value: s.recordButton,
              onChanged: (v) => s.update((s) => s.recordButton = v),
            ),
            ListTile(
              leading: const Icon(Icons.movie),
              title: const Text('점검 화면을 녹화로 시험'),
              subtitle: Text(s.replayPath.isEmpty
                  ? '끔 — 카메라 사용'
                  : '켬: ${recordingTitle(s.replayPath.split(RegExp(r'[\\/]')).last)} '
                      '(카메라 대신 이 녹화가 반복 재생, 탐지·추적·AI 점검은 그대로)'),
              onTap: () async {
                final path = await pickRecording(context, allowOff: true);
                if (path != null) await s.update((s) => s.replayPath = path);
              },
            ),
            ListTile(
              leading: const Icon(Icons.speed),
              title: const Text('카메라 테스트 화면'),
              subtitle: const Text('FPS·추론 시간·해상도·테스트 이미지 확인'),
              onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => CameraTestScreen(settings: s))),
            ),
            const ListTile(
              dense: true,
              title: Text('안내'),
              subtitle: Text('API 키가 앱에 들어 있어 APK에서 추출될 수 있습니다. '
                  '대회 시연용이며, 실서비스는 서버를 거쳐야 합니다.'),
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
        child: Text(text,
            style: TextStyle(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.bold)),
      );
}
