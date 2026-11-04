import 'dart:convert';
import 'dart:io';
import 'package:camera/camera.dart' show ResolutionPreset;
import 'package:flutter/foundation.dart';

/// 앱 설정. 기기 안 json 파일 하나에 저장(설정 화면에서 바꾸면 바로 반영).
class AppSettings extends ChangeNotifier {
  AppSettings(this.file);

  final File file;

  /// 기본 720p: 에뮬레이터 측정에서 15FPS 상한과 함께 쓰면 480p·상한 없음보다
  /// 처리도 빠르고 AI 스냅샷은 3배 화소 (PROGRESS.md 해상도 표)
  ResolutionPreset preset = ResolutionPreset.high;

  /// 카메라 FPS 상한(0 = 기기 기본). 버릴 프레임 변환에 CPU를 덜 써서 탐지가 빨라짐
  int cameraFps = 15;

  /// 자이로로 폰 회전을 보정해 추적(자율주행의 IMU 보정)
  bool gyro = true;

  /// 새 물체가 나타나면 AI 자동 점검
  bool autoAi = false;
  int autoAiCooldownSec = 15;

  /// 자동 점검에서 위험요소가 나오면 발견사항으로 바로 저장
  bool autoSaveHazards = true;

  /// 실시간 탐지 박스 표시
  bool showDetections = true;

  /// 어두우면 카메라 노출을 자동으로 올림(손전등 없이도 밝게)
  bool autoExposure = true;

  /// 카메라에 비친 손가락으로 위험 박스를 눌러 무시·완료(AR, 손 인식은 위험 표시가 떠 있을 때만 돎)
  bool handControl = true;

  /// (개발자) 분석 로그 기록: ML Kit 원본 탐지·자이로를 파일로 남겨 PC에서 추적기를 다시 돌려 봄
  bool analysisLog = false;

  /// (개발자) 탐지기 학습 데이터 모으기: AI 점검 때 설비 위치도 받아 사진과 함께 저장(YOLO 형식)
  bool collectEquipment = false;

  /// (개발자) 물체 탐지에 ML Kit 대신 설비 전용 탐지기(YOLOE 시험 모델, 밸브·배관·분전반 등 10종)
  bool equipmentDetector = false;

  /// (개발자) 카메라 화면에 시험용 녹화 버튼(카메라 원본 + 자이로를 남겨 나중에 같은 장면으로 새 기능 시험)
  bool recordButton = false;

  /// (개발자) 점검 화면을 카메라 대신 이 녹화로 시험(비우면 카메라). 녹화 폴더 경로
  String replayPath = '';

  /// 이 시간(분) 동안 화면을 안 만지면 카메라를 멈춰 배터리 절약(0 = 안 멈춤)
  int idlePauseMin = 5;

  /// 점검 화면 사용 팁을 이미 봤는지(처음 한 번만 보여 줌)
  bool seenCameraTips = false;
  static const idleChoices = [0, 2, 5, 10];

  static const fpsChoices = [0, 10, 15, 30];
  static const presetChoices = [
    ResolutionPreset.low,
    ResolutionPreset.medium,
    ResolutionPreset.high,
    ResolutionPreset.veryHigh,
  ];

  Future<void> load() async {
    try {
      if (!await file.exists()) return;
      final j = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      preset = ResolutionPreset.values.asNameMap()[j['preset']] ?? preset;
      cameraFps = (j['cameraFps'] as num?)?.toInt() ?? cameraFps;
      gyro = j['gyro'] as bool? ?? gyro;
      autoAi = j['autoAi'] as bool? ?? autoAi;
      autoAiCooldownSec =
          (j['autoAiCooldownSec'] as num?)?.toInt() ?? autoAiCooldownSec;
      autoSaveHazards = j['autoSaveHazards'] as bool? ?? autoSaveHazards;
      showDetections = j['showDetections'] as bool? ?? showDetections;
      autoExposure = j['autoExposure'] as bool? ?? autoExposure;
      handControl = j['handControl'] as bool? ?? handControl;
      analysisLog = j['analysisLog'] as bool? ?? analysisLog;
      collectEquipment = j['collectEquipment'] as bool? ?? collectEquipment;
      equipmentDetector = j['equipmentDetector'] as bool? ?? equipmentDetector;
      recordButton = j['recordButton'] as bool? ?? recordButton;
      replayPath = j['replayPath'] as String? ?? replayPath;
      idlePauseMin = (j['idlePauseMin'] as num?)?.toInt() ?? idlePauseMin;
      seenCameraTips = j['seenCameraTips'] as bool? ?? seenCameraTips;
    } catch (e) {
      debugPrint('설정 읽기 실패, 기본값 사용: $e');
    }
    notifyListeners();
  }

  /// 값을 바꾸고 저장: settings.update((s) => s.gyro = false)
  Future<void> update(void Function(AppSettings s) change) async {
    change(this);
    notifyListeners();
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode({
      'preset': preset.name,
      'cameraFps': cameraFps,
      'gyro': gyro,
      'autoAi': autoAi,
      'autoAiCooldownSec': autoAiCooldownSec,
      'autoSaveHazards': autoSaveHazards,
      'showDetections': showDetections,
      'autoExposure': autoExposure,
      'handControl': handControl,
      'analysisLog': analysisLog,
      'collectEquipment': collectEquipment,
      'equipmentDetector': equipmentDetector,
      'recordButton': recordButton,
      'replayPath': replayPath,
      'idlePauseMin': idlePauseMin,
      'seenCameraTips': seenCameraTips,
    }));
  }
}
