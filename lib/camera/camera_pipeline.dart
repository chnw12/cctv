import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:camera/camera.dart' show CameraException;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import '../analysis/default_analyzer.dart';
import '../analysis/hazard.dart';
import '../analysis/hazard_analyzer.dart';
import '../core/frame.dart';
import 'hazard_anchor.dart';
import '../data/app_settings.dart';
import '../data/equipment_dataset.dart';
import '../detection/detector.dart';
import '../detection/equipment_detector.dart';
import '../detection/mlkit_detector.dart';
import '../detection/tracking_detector.dart';
import '../hands/hand_tracker.dart';
import 'analysis_log.dart';
import 'camera_recorder.dart';
import '../motion/camera_motion.dart';
import '../sources/camera_frame_source.dart';
import '../sources/frame_source.dart';
import '../sources/image_sequence_frame_source.dart';
import '../sources/recording_frame_source.dart';

/// camera: 폰 카메라(설정에서 "점검 화면을 녹화로 시험"을 골랐으면 그 녹화), images: 테스트 사진,
/// recording: [CameraPipeline.replayDir] 녹화 재생(카메라와 같은 길: 추적·자이로·손 인식)
enum SourceKind { camera, images, recording }

class Metrics {
  final int inFps; // 입력(카메라)이 넘겨준 프레임 수/초
  final int fps; // 탐지 완료 수/초
  final int count;
  final int inferMs;
  final Size frameSize; // 분석 프레임(똑바로 선) 크기
  const Metrics(this.inFps, this.fps, this.count, this.inferMs, this.frameSize);
}

/// AI 점검 한 번의 상태. 결과에는 분석한 사진(jpeg)도 같이 있어 그대로 기록으로 저장 가능
class AiState {
  final bool running;
  final HazardReport? report;
  final String? error;
  final Uint8List? jpeg;

  /// 촬영+축소에 걸린 시간(해상도에 따라 달라짐)
  final int? snapshotMs;

  /// 자동 점검(새 물체 등장)으로 실행됐는지
  final bool auto;

  const AiState(
      {this.running = false,
      this.report,
      this.error,
      this.jpeg,
      this.snapshotMs,
      this.auto = false});
}

/// 카메라 입력 → 탐지·추적(자이로 보정) → AI 점검을 묶은 재사용 컨트롤러.
/// 점검 화면과 카메라 테스트 화면이 같이 씁니다. 화면은 이 객체의 ValueNotifier만 그립니다.
class CameraPipeline extends ChangeNotifier {
  /// sourceFactory·detectorFactory는 테스트용(가짜 카메라·탐지기). 비우면 실제 카메라·ML Kit
  CameraPipeline({
    required this.settings,
    HazardAnalyzer? analyzer,
    this.sourceFactory,
    this.detectorFactory,
    this.motionFactory,
    this.handFactory,
    this.logDir,
  }) : analyzer = analyzer ?? createDefaultAnalyzer() {
    _autoAi = settings.autoAi;
    _cameraKey = _keyOf(settings);
    settings.addListener(_onSettings);
    // 백그라운드에서 카메라를 잡고 있으면 엔진이 떨어진 뒤 프레임이 와서
    // "FlutterJNI is not attached" 크래시(에뮬레이터 재현) → 화면이 가려지면 닫고 돌아오면 다시 열기.
    // inactive(권한 팝업·알림창)에는 반응하지 않음
    _lifecycle = AppLifecycleListener(
      onHide: () => _serial(_close),
      onShow: () {
        if (_wantOpen) _serial(() => _open(_kind));
      },
    );
  }

  final AppSettings settings;
  final HazardAnalyzer analyzer;
  final FrameSource Function(SourceKind kind)? sourceFactory;
  final Detector Function()? detectorFactory;
  final GyroCameraMotion Function()? motionFactory;
  final HandTracker Function()? handFactory;

  /// 분석 로그·학습 데이터를 쓸 폴더(설정에서 켰을 때). 비우면 앱 외부 저장소(adb로 꺼낼 수 있는 곳)
  /// 아래 analysis_logs / equipment_dataset
  final Future<Directory?> Function()? logDir;
  AnalysisLog? _log;

  /// 지금 기록 중인 분석 로그 파일(없으면 null)
  File? get logFile => _log?.file;

  /// 시험용 녹화(카메라 원본 + 자이로). 녹화 중이면 그 녹화기, 아니면 null(화면이 듣고 버튼·시간 표시)
  final recording = ValueNotifier<CameraRecorder?>(null);

  /// [SourceKind.recording]으로 열 때 재생할 녹화 폴더
  Directory? replayDir;

  /// AI 결과가 나올 때마다(수동·자동). 점검 화면이 자동 저장에 사용
  void Function(AiState result)? onAiResult;

  /// 점검 장소(AI 프롬프트에 넣음). 점검 화면이 설정
  String? place;

  late final AppLifecycleListener _lifecycle;
  Detector? _detector;
  GyroCameraMotion? _motion;
  FrameSource? _source;
  StreamSubscription<Frame>? _sub;
  SourceKind _kind = SourceKind.camera;
  String? _error;
  bool _busy = false;
  bool _wantOpen = false;
  bool _disposed = false;
  String _cameraKey = '';

  final detections = ValueNotifier<List<Detection>>(const []);
  final metrics = ValueNotifier<Metrics>(const Metrics(0, 0, 0, 0, Size.zero));
  final ai = ValueNotifier<AiState?>(null);

  /// AI 사진을 찍은 뒤 카메라가 움직여 화면이 밀린 누적량(자이로, 화면 비율).
  /// 위험 박스를 이만큼 옮겨 그리면 폰을 움직여도 표시가 실제 위험 위치에 붙어 있음
  /// (자율주행이 자차 움직임을 빼서 정지 장애물 위치를 유지하는 것과 같은 원리)
  final hazardShift = ValueNotifier<Offset>(Offset.zero);
  int? _anchorMs; // 누적 시작 시각(= 사진 찍은 시각)

  /// 추적 중인 물체에 붙은 위험 표시의 현재 위치(위험 번호 → 박스). 여기 없는 위험은 hazardShift로 옮김
  final hazardAnchored = ValueNotifier<Map<int, Rect>>(const {});

  /// 손 인식 결과(AR: 손가락으로 위험 박스 누르기). 처리 안 된 위험 표시가 떠 있을 때만 돌고, 아니면 null
  final hand = ValueNotifier<HandFrame?>(null);
  HandTracker? _hands;
  bool _handBusy = false, _handBroken = false;
  int _lastHandMs = 0, _handMs = 0;

  /// 손 인식 최소 간격(최대 초당 15번, 실제로는 인식 시간에 맞춰짐)
  static const handIntervalMs = 66;

  /// 폰이 빠르게 도는 중(손가락 누르기 진행 안 함)
  bool get movingFast => (_motion?.lastRate.distance ?? 0) > 0.5;

  /// 위험의 처리 상태(무시·완료)가 바뀔 때마다 +1 → 화면이 다시 그림.
  /// 상태는 결과 객체(Hazard) 안에 있어 값이 바뀌어도 알림이 안 오므로 바꾼 쪽이 [markHazardsChanged] 호출
  final hazardRevision = ValueNotifier<int>(0);
  void markHazardsChanged() => hazardRevision.value++;
  List<Detection> _snapTracks = const [];
  Map<int, HazardAnchor> _anchors = const {};

  /// 장면이 어두운지(손전등 권유용). 밝기 50 미만이면 어둡다, 70 넘으면 밝다(깜빡임 방지 히스테리시스)
  final isDark = ValueNotifier<bool>(false);
  int _lumaCounter = 0;
  final _inTimes = <int>[];
  final _doneTimes = <int>[];
  final _seenIds = <int>{};
  bool _autoAi = false;
  int _lastAiMs = 0;
  int _lastPerfLogMs = 0;

  SourceKind get kind => _kind;
  FrameSource? get source => _source;
  CameraControls? get controls => _source?.controls;
  String? get error => _error;
  bool get aiAvailable => analyzer.unavailableReason == null;

  bool get autoAi => _autoAi;
  set autoAi(bool v) {
    _autoAi = v;
    notifyListeners();
  }

  // ── 열기/닫기 ─────────────────────────────────────────────
  /// 열기/닫기가 겹치지 않게 순서대로 실행(빠른 전환·생명주기 이벤트 연타 대비)
  Future<void> _queue = Future.value();

  Future<void> _serial(Future<void> Function() step) => _queue = _queue
      .then((_) => step())
      .catchError((Object e) => debugPrint('source lifecycle error: $e'));

  Future<void> open(SourceKind kind) {
    _wantOpen = true;
    return _serial(() => _open(kind));
  }

  Future<void> close() {
    _wantOpen = false;
    return _serial(_close);
  }

  /// 카메라 설정(해상도·FPS·자이로)이 바뀌면 다시 열기
  void _onSettings() {
    _applyAutoExposure();
    final k = _keyOf(settings);
    if (k == _cameraKey) return;
    _cameraKey = k;
    if (_wantOpen) _serial(() => _open(_kind));
  }

  static String _keyOf(AppSettings s) =>
      '${s.preset.name}/${s.cameraFps}/${s.gyro}/${s.equipmentDetector}/${s.replayPath}';

  Future<void> _close() async {
    await _sub?.cancel();
    _sub = null;
    _pending = null;
    await _source?.dispose();
    _source = null;
    await _detector?.close();
    _detector = null;
    await _motion?.stop();
    _motion = null;
    await _closeHands();
    await _log?.close();
    _log = null;
    await stopRecording(); // 화면을 떠나거나 백그라운드로 가면 녹화도 마무리
    detections.value = const [];
    _inTimes.clear();
    _doneTimes.clear();
    _seenIds.clear();
    if (ai.value?.running == true) ai.value = null;
    _notify();
  }

  Future<void> _open(SourceKind kind) async {
    await _close();
    if (_disposed) return;
    _kind = kind;
    _error = null;
    _notify();
    final FrameSource src = sourceFactory?.call(kind) ?? _sourceFor(kind);
    try {
      await src.start();
    } catch (e) {
      debugPrint('카메라 열기 실패(${kind.name}): $e');
      await src.dispose();
      _error = describeCameraError(e);
      _notify();
      return;
    }
    if (_disposed || !_wantOpen) {
      await src.dispose();
      return;
    }
    _source = src;
    // 카메라·녹화 재생은 연속 프레임이라 추적(+자이로 보정), 테스트 사진은 서로 무관하니 추적 안 함
    if (kind != SourceKind.images) {
      final replay = src is RecordingFrameSource ? src : null;
      final motion = settings.gyro
          ? (_motion = motionFactory?.call() ?? GyroCameraMotion())
          : null;
      final fov = replay?.lensFov ?? src.controls?.lensFov;
      if (fov != null) motion?.useLensFov(fov.width, fov.height);
      if (replay != null) {
        // 녹화 재생: 자이로 센서 대신 녹화된 자이로·줌을 같은 시각에 넣음
        motion?.zoom = replay.zoom;
        replay.gyro.listen((g) => motion?.addSample(g.$1, g.$2, g.$3));
        replay.zooms.listen((z) => motion?.zoom = z);
      } else {
        await motion?.start(); // 자이로 없는 기기면 이동량 0 → 박스 정렬 보정만으로 동작
      }
      _log = await _openLog(src, fov);
      // 원본 자이로·탐지는 분석 로그와 녹화(켜져 있으면) 양쪽에 적음
      motion?.onSample = (ms, x, y) {
        _log?.gyro(ms, x, y);
        recording.value?.gyro(ms, x, y);
      };
      final inner = LoggingDetector(_newDetector(), (ms, raw) {
        _log?.frame(ms, raw);
        recording.value?.detections(ms, raw);
      });
      _detector = TrackingDetector(inner, motion: motion);
    } else {
      _detector = _newDetector();
    }
    _sub = src.frames.listen(_onFrame);
    _stillSinceMs = null;
    _ev = 0; // 새 카메라는 보정 없이 열림 → 여전히 어두우면 다시 올림
    _applyAutoExposure();
    _notify();
  }

  /// 재생할 녹화: [SourceKind.recording]은 [replayDir], 카메라는 설정 "점검 화면을 녹화로 시험"이 골라 둔 녹화
  FrameSource _sourceFor(SourceKind kind) {
    final replay = switch (kind) {
      SourceKind.recording => replayDir,
      SourceKind.camera when settings.replayPath.isNotEmpty =>
        Directory(settings.replayPath),
      _ => null,
    };
    if (replay != null) return RecordingFrameSource(replay);
    return kind == SourceKind.images
        ? ImageSequenceFrameSource()
        : CameraFrameSource(
            preset: settings.preset,
            fps: settings.cameraFps > 0 ? settings.cameraFps : null);
  }

  /// 카메라 상태(분석 로그·녹화 맨 앞에 적음)
  Map<String, Object?> _metaFor(FrameSource src, Size? lensFov) => {
        'v': 1,
        'started': DateTime.now().toIso8601String(),
        'preset': settings.preset.name,
        'camFps': settings.cameraFps,
        'gyro': settings.gyro,
        'detector': settings.equipmentDetector ? 'equipment' : 'mlkit',
        if (lensFov != null) 'lensFov': [lensFov.width, lensFov.height],
        'zoom': src.controls?.zoom ?? 1,
      };

  /// 시험용 녹화 시작(카메라일 때만, 녹화를 재생 중이면 안 함). 폴더: 외부 저장소/recordings/<시각>
  Future<void> startRecording() async {
    final src = _source;
    if (recording.value != null || src == null || src is RecordingFrameSource) {
      return;
    }
    if (_kind == SourceKind.images) return;
    final dir = await (logDir?.call() ?? getExternalStorageDirectory());
    if (dir == null || _source != src) return;
    final stamp =
        DateTime.now().toIso8601String().replaceAll(':', '').split('.').first;
    final r = CameraRecorder(Directory('${dir.path}/recordings/$stamp'))
      ..start(_metaFor(src, src.controls?.lensFov));
    recording.value = r;
    debugPrint('PERF recording start ${r.dir.path}');
  }

  /// 녹화 멈춤 → 마무리한 녹화기(요약 표시용), 녹화 중이 아니면 null.
  /// 남은 저장이 끝난 뒤에 [recording]을 비워 화면 알림의 장 수가 최종값이 되게 함
  Future<CameraRecorder?> stopRecording() async {
    final r = recording.value;
    if (r == null || r.stopping) return null;
    await r.stop();
    lastRecording = r;
    if (recording.value == r) recording.value = null;
    debugPrint('PERF recording stop frames=${r.frames} dropped=${r.dropped} '
        's=${r.seconds.toStringAsFixed(1)} mb=${(r.bytes / 1e6).toStringAsFixed(1)}');
    return r;
  }

  /// 가장 최근에 끝난 녹화(10분 자동 멈춤 뒤 화면이 요약을 보여 줄 때)
  CameraRecorder? lastRecording;

  Detector _newDetector() =>
      detectorFactory?.call() ??
      (settings.equipmentDetector ? EquipmentDetector() : MlKitDetector());

  /// 설정에서 켰으면 새 분석 로그 파일을 엶(카메라를 열 때마다 한 파일). 녹화 재생 중에는 안 남김
  Future<AnalysisLog?> _openLog(FrameSource src, Size? lensFov) async {
    if (!settings.analysisLog || src is RecordingFrameSource) return null;
    try {
      final dir = await (logDir?.call() ?? getExternalStorageDirectory());
      if (dir == null) return null;
      final now = DateTime.now();
      final stamp = now.toIso8601String().replaceAll(':', '').split('.').first;
      final log = AnalysisLog(File('${dir.path}/analysis_logs/$stamp.jsonl'));
      log.open(_metaFor(src, lensFov));
      debugPrint('PERF analysis log ${log.file.path}');
      return log;
    } catch (e) {
      debugPrint('분석 로그를 열 수 없음: $e');
      return null;
    }
  }

  /// 현장에서 바로 알아볼 수 있는 카메라 오류 문구
  static String describeCameraError(Object e) {
    if (e is CameraException) {
      switch (e.code) {
        case 'CameraAccessDenied':
        case 'CameraAccessDeniedWithoutPrompt':
        case 'CameraAccessRestricted':
          return '카메라 권한이 필요합니다.\n설정 > 애플리케이션 > 이 앱 > 권한에서 카메라를 허용한 뒤 다시 시도하세요.';
      }
      return '카메라를 열 수 없습니다(${e.code}). 다른 앱이 카메라를 쓰고 있는지 확인하세요.';
    }
    if (e is StateError) return e.message;
    return '$e';
  }

  // ── 프레임 처리 ───────────────────────────────────────────
  /// 처리 중에 온 프레임은 "가장 최근 것 하나"만 남겨 두었다가 끝나자마자 처리(CameraX의
  /// KEEP_ONLY_LATEST와 같은 방식, 밀리지 않음). 그냥 버리면 추론(실기기 약 70ms)이 프레임 간격
  /// (15FPS = 66ms)보다 조금만 길어도 한 장씩 건너뛰어 처리가 절반(Z Flip7 실측 8/15FPS)으로 떨어짐.
  /// FPS = 1초간 "처리 완료" 횟수.
  void _onFrame(Frame f) {
    _tick(_inTimes, DateTime.now().millisecondsSinceEpoch);
    final rec = recording.value;
    if (rec != null) {
      rec.addFrame(f); // 절전 중에도 카메라 원본은 전부 남김
      if (rec.seconds >= CameraRecorder.maxSeconds) unawaited(stopRecording());
    }
    _maybeHands(f); // 물체 탐지와 따로(다른 스레드) 돌아 서로 기다리지 않음
    if (_busy) {
      _pending = f;
      return;
    }
    _process(f);
  }

  Frame? _pending;

  Future<void> _process(Frame f) async {
    final detector = _detector;
    if (detector == null || _skipForEco(f.timestampMs)) return;
    _busy = true;
    final sw = Stopwatch()..start();
    try {
      final result = await detector.detect(f);
      sw.stop();
      if (_detector != detector) return; // 처리 중에 소스가 바뀜
      _lastProcMs = f.timestampMs;
      // 처음 보는 물체(새 확정 ID)가 나타나면 다시 전부 처리. 탐지 개수로 보던 이전 방식은 실기기에서
      // ML Kit 박스 수가 프레임마다 깜빡여(1↔2) 가만히 들고 있어도 절전이 한 번도 안 켜졌음
      if (result.any(
          (d) => d.trackingId != null && !_seenIds.contains(d.trackingId))) {
        _stillSinceMs = null;
      }
      detections.value = result;
      _accumulateHazardShift(f.timestampMs);
      _accumulateViewChange(f.timestampMs);
      _followAnchors(result);
      if (_lumaCounter++ % 5 == 0) _measureBrightness(f);
      final now = DateTime.now().millisecondsSinceEpoch;
      _tick(_doneTimes, now);
      final m = Metrics(_inTimes.length, _doneTimes.length, result.length,
          sw.elapsedMilliseconds, f.uprightSize);
      metrics.value = m;
      _logPerf(m, now);
      _maybeAutoAi(result, now);
    } catch (e) {
      debugPrint('detect error: $e');
    } finally {
      _busy = false;
      final next = _pending;
      _pending = null;
      if (next != null && _detector == detector) _process(next);
    }
  }

  // ── 손 인식(AR) ──
  /// 처리 안 된 위험 박스가 있을 때만 손을 찾음(손가락으로 누를 대상이 없으면 안 돌려 물체 처리 속도 유지).
  /// 실패하면(모델·네이티브 라이브러리 없음 등) 이번 실행 동안 끄고 화면 탭만 남김
  void _maybeHands(Frame f) {
    final r = ai.value?.report;
    final want = settings.handControl &&
        !_handBroken &&
        r != null &&
        r.hazards.any((h) => h.status == HazardStatus.open && h.box != null);
    if (!want) {
      if (hand.value != null) hand.value = null;
      return;
    }
    if (_handBusy || f.timestampMs - _lastHandMs < handIntervalMs) return;
    _handBusy = true;
    _lastHandMs = f.timestampMs;
    final tracker = _hands ??= handFactory?.call() ?? MediaPipeHandTracker();
    final sw = Stopwatch()..start();
    tracker.detect(f).then((hs) {
      if (_disposed || _hands != tracker) return;
      _handMs = sw.elapsedMilliseconds;
      hand.value = HandFrame(f.timestampMs, hs);
    }).catchError((Object e) {
      debugPrint('손 인식 사용 불가, 화면 탭만 사용: $e');
      _handBroken = true;
      if (!_disposed) hand.value = null;
    }).whenComplete(() => _handBusy = false);
  }

  Future<void> _closeHands() async {
    final t = _hands;
    _hands = null;
    if (!_disposed) hand.value = null;
    try {
      await t?.close();
    } catch (_) {}
  }

  // ── 절전: 가만히 있으면 처리 줄이기 ──
  int? _stillSinceMs;
  int _lastProcMs = 0;
  static const ecoAfterMs = 3000, ecoIntervalMs = 500, ecoRate = 0.05;

  /// 카메라 테스트 화면은 FPS 측정용이라 끔
  bool ecoEnabled = true;

  /// 지금 처리를 줄인 상태인지(로그용)
  bool get eco =>
      _stillSinceMs != null && _lastProcMs - _stillSinceMs! >= ecoAfterMs;

  /// 폰이 가만히 있고(자이로 ±0.05rad/s 이내) 새 물체도 안 나타난 채 3초가 지나면
  /// 처리를 초당 2번으로 줄임(배터리·발열). 돌리거나 처음 보는 물체가 나타나면 바로 전부 처리.
  /// 자이로가 없으면 가만히 있는지 알 수 없어 줄이지 않음
  bool _skipForEco(int t) {
    final g = _motion;
    if (g == null || !ecoEnabled) return false;
    final r = g.lastRate;
    if (r.dx.abs() > ecoRate || r.dy.abs() > ecoRate) {
      _stillSinceMs = null;
      return false;
    }
    final since = _stillSinceMs ??= t;
    return t - since >= ecoAfterMs && t - _lastProcMs < ecoIntervalMs;
  }

  void _followAnchors(List<Detection> tracks) {
    final r = ai.value?.report;
    if (_anchors.isEmpty || r == null) return;
    hazardAnchored.value = HazardAnchor.place(r.hazards, _anchors, tracks);
  }

  void _resetAnchors() {
    _anchorMs = null;
    hazardShift.value = Offset.zero;
    _snapTracks = const [];
    _anchors = const {};
    hazardAnchored.value = const {};
  }

  void _accumulateHazardShift(int frameMs) {
    final m = _motion, from = _anchorMs;
    if (m == null || from == null || frameMs <= from) return;
    final (s, next) = m.shiftSince(from, frameMs);
    hazardShift.value += s;
    _anchorMs = next;
  }

  /// NV21 앞부분(Y 평면 = 밝기)만 듬성듬성 읽어 평균 밝기(0~255)
  static double? meanLuma(Uint8List bytes, int pixels, {int step = 97}) {
    final n = pixels.clamp(0, bytes.length);
    var sum = 0, count = 0;
    for (var i = 0; i < n; i += step) {
      sum += bytes[i];
      count++;
    }
    return count == 0 ? null : sum / count;
  }

  void _measureBrightness(Frame f) {
    final b = f.bytes, raw = f.rawSize;
    if (b == null || raw == null || f.format != FrameFormat.nv21) return;
    final mean = meanLuma(b, (raw.width * raw.height).toInt());
    if (mean == null) return;
    // 노출을 올린 동안엔 그만큼 밝게 찍히므로 원래 밝기로 환산해서 판정
    // (안 그러면 올림 → 밝음 판정 → 내림 → 어두움 판정 … 반복)
    final base = mean / math.pow(2, _ev);
    if (isDark.value ? base > 70 : base < 50) {
      isDark.value = !isDark.value;
      // 실기기 테스트에서 깜빡임(짧은 시간 안에 여러 번 뒤집힘) 확인용
      debugPrint('PERF exposure dark=${isDark.value} luma=${mean.round()} '
          'base=${base.round()} ev=$_ev');
      _applyAutoExposure();
    }
  }

  /// 어두워지면 노출을 +1EV(지원 범위 안), 밝아지면 원래대로. 손전등이 없거나
  /// 반짝이는 배관에 손전등이 번질 때도 화면·AI 사진이 밝아짐
  /// 설정을 끄면 바로 원래대로
  Future<void> _applyAutoExposure() async {
    final c = controls;
    if (c == null || c.maxExposureOffset <= 0) return;
    final want = settings.autoExposure && isDark.value
        ? math.min(autoExposureEv, c.maxExposureOffset)
        : 0.0;
    if (want == _ev) return;
    _ev = want;
    try {
      await c.setExposureOffset(want);
    } catch (_) {
      _ev = 0; // 기기가 거부하면 보정 없음으로 보고 판정
    }
  }

  static const autoExposureEv = 1.0;

  /// 지금 카메라에 걸어 둔 노출 보정(EV)
  double _ev = 0;

  /// 최근 1초 안의 이벤트만 남김 → length가 초당 횟수
  static void _tick(List<int> times, int now) => times
    ..add(now)
    ..removeWhere((t) => now - t >= 1000);

  /// 성능 로그(5초마다). `adb logcat | grep PERF` 로 수치를 모읍니다.
  void _logPerf(Metrics m, int now) {
    if (now - _lastPerfLogMs < 5000) return;
    _lastPerfLogMs = now;
    final g = _motion;
    debugPrint('PERF source=${_kind.name} preset=${settings.preset.name} '
        'camFps=${settings.cameraFps == 0 ? "기본" : settings.cameraFps} '
        'frame=${m.frameSize.width.toInt()}x${m.frameSize.height.toInt()} '
        'in=${m.inFps} proc=${m.fps} infer=${m.inferMs}ms objs=${m.count} ids=${_seenIds.length}'
        '${controls == null ? '' : ' zoom=${controls!.zoom.toStringAsFixed(1)}/${controls!.minZoom.toStringAsFixed(1)}~${controls!.maxZoom.toStringAsFixed(1)}'}'
        '${controls == null ? '' : ' dark=${isDark.value} ev=$_ev/${controls!.maxExposureOffset}'}'
        '${hand.value == null ? '' : ' hand=${_handMs}ms hands=${hand.value!.hands.length}'}'
        '${g == null ? '' : ' gyro=${g.lastRate.dx.toStringAsFixed(2)},${g.lastRate.dy.toStringAsFixed(2)}rad/s fovX=${(57.3 / g.radToX).round()}°${g.lensFovX == null ? '' : ' lensX=${(57.3 * g.lensFovX!).round()}°'} bias=${g.bias.dx.toStringAsFixed(4)},${g.bias.dy.toStringAsFixed(4)}${eco ? ' eco' : ''}'}');
  }

  /// 처음 보는 trackingId가 나타나면 AI 점검. 비용 때문에 쿨다운을 둡니다.
  void _maybeAutoAi(List<Detection> result, int now) {
    var fresh = false;
    for (final id in result.map((d) => d.trackingId).whereType<int>()) {
      if (_seenIds.add(id)) fresh = true;
    }
    // 손을 비추는 동안(위험 박스를 누르는 중)은 손이 새 물체로 잡혀도 자동 점검 안 함
    final handIn = hand.value?.hands.isNotEmpty == true;
    if (_autoAi &&
        !handIn &&
        (fresh || _isNewView) &&
        aiAvailable &&
        now - _lastAiMs > settings.autoAiCooldownSec * 1000) {
      runAi(auto: true);
    }
  }

  // ── 새 장면 감지(키프레임) ──
  // ML Kit 기본 모델은 배관·밸브를 잘 못 잡아 "새 물체"만으로는 자동 점검이 거의 안 돌 수 있음.
  // 자율주행·SLAM이 움직임이 충분할 때 키프레임을 고르듯, 마지막 AI 점검 뒤 카메라가 화면 폭의
  // 일정 비율 이상 돌아가 다른 곳을 보고 있고 지금 멈춰 있으면 "새 장면"으로 봄
  double _viewChange = 0; // 마지막 AI 점검 뒤 누적 화면 이동량(화면 비율)
  int? _viewMs;

  /// 이만큼(화면 폭 비율) 돌아가면 새 장면
  static const newViewShift = 0.6;

  bool get _isNewView =>
      _viewChange >= newViewShift &&
      (_motion?.lastRate.distance ?? double.infinity) <= steadyRadPerSec;

  void _accumulateViewChange(int frameMs) {
    final m = _motion, from = _viewMs;
    if (m == null || from == null) {
      _viewMs = frameMs;
      return;
    }
    final (s, next) = m.shiftSince(from, frameMs);
    _viewChange += s.distance;
    _viewMs = next;
  }

  // ── AI 점검·촬영 ───────────────────────────────────────────
  Future<void> runAi({bool auto = false}) async {
    final src = _source;
    if (src == null || ai.value?.running == true) return;
    _lastAiMs = DateTime.now().millisecondsSinceEpoch;
    ai.value = AiState(running: true, auto: auto);
    _viewChange = 0; // 이 장면은 점검함
    _resetAnchors();
    AiState result;
    Uint8List? shot; // 분석이 실패해도 찍은 사진은 남겨 "사진만 저장"에 씀
    try {
      final reason = analyzer.unavailableReason;
      if (reason != null) throw StateError(reason);
      final waited = await _waitSteady();
      _anchorMs = DateTime.now().millisecondsSinceEpoch;
      _snapTracks = detections.value; // 찍는 순간 보이던 물체들(위험 표시를 붙일 후보)
      final sw = Stopwatch()..start();
      final jpeg = shot = await src.snapshotJpeg();
      final snapMs = sw.elapsedMilliseconds;
      final collect = settings.collectEquipment;
      final report =
          await analyzer.analyze(jpeg, place: place, equipment: collect);
      if (collect) collecting = _collect(jpeg, report);
      debugPrint('PERF snapshot preset=${settings.preset.name} '
          'size=${report.imageSize.width.toInt()}x${report.imageSize.height.toInt()} '
          'kb=${jpeg.length ~/ 1024} steady=${waited}ms capture=${snapMs}ms ai=${report.elapsedMs}ms');
      result =
          AiState(report: report, jpeg: jpeg, snapshotMs: snapMs, auto: auto);
    } catch (e) {
      debugPrint('AI 점검 실패(${auto ? '자동' : '수동'}): $e');
      // StateError는 'Bad state:' 접두어 없이 메시지만
      result = AiState(
          error: e is StateError ? e.message : '$e', jpeg: shot, auto: auto);
    }
    if (_source != src || _disposed) return; // 그 사이 화면을 떠남
    final report = result.report;
    if (report != null) {
      _anchors = HazardAnchor.match(report.hazards, _snapTracks);
      hazardAnchored.value =
          HazardAnchor.place(report.hazards, _anchors, detections.value);
    }
    ai.value = result;
    onAiResult?.call(result);
  }

  /// 진행 중인 학습 데이터 저장(점검 결과는 기다리지 않고 바로 보여 줌, 테스트가 끝날 때 기다림)
  @visibleForTesting
  Future<void> collecting = Future.value();

  /// 설비 박스를 학습 데이터로 저장(실패해도 점검은 그대로)
  Future<void> _collect(Uint8List jpeg, HazardReport report) async {
    try {
      final dir = await (logDir?.call() ?? getExternalStorageDirectory());
      if (dir == null) return;
      final saved =
          await EquipmentDataset(Directory('${dir.path}/equipment_dataset'))
              .add(jpeg, report, place: place);
      debugPrint('PERF dataset equipment=${report.equipment.length} '
          '${saved?.path ?? '(설비 없음, 저장 안 함)'}');
    } catch (e) {
      debugPrint('학습 데이터 저장 실패: $e');
    }
  }

  /// 손이 흔들리는 중이면 멈출 때까지 잠깐(최대 0.7초) 기다렸다 찍음 → 흐린 사진 방지.
  /// 자율주행이 IMU로 움직임을 보고 센서 값을 고르는 것처럼, 자이로가 조용할 때를 고름
  Future<int> _waitSteady() async {
    final g = _motion;
    if (g == null) return 0;
    final sw = Stopwatch()..start();
    while (sw.elapsedMilliseconds < maxSteadyWaitMs &&
        g.lastRate.distance > steadyRadPerSec) {
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
    return sw.elapsedMilliseconds;
  }

  static const steadyRadPerSec = 0.25;
  static const maxSteadyWaitMs = 700;

  /// AI 없이 지금 장면 사진만(오프라인 기록·직접 메모용)
  Future<Uint8List> capturePhoto() async {
    final src = _source;
    if (src == null) throw StateError('카메라 준비 안 됨');
    return src.snapshotJpeg();
  }

  void clearAi() {
    ai.value = null;
    hand.value = null;
    _resetAnchors();
  }

  // ── 카메라 조작 ───────────────────────────────────────────
  Future<void> setTorch(bool on) async {
    final c = controls;
    if (c == null) return;
    await c.setTorch(on);
    _notify();
  }

  Future<void> setZoom(double zoom) async {
    final c = controls;
    if (c == null) return;
    await c.setZoom(zoom);
    _motion?.zoom = c.zoom; // 줌 배율만큼 화각이 좁아짐 → 자이로 환산도 같이
    _log?.zoom(DateTime.now().millisecondsSinceEpoch, c.zoom);
    recording.value?.zoom(DateTime.now().millisecondsSinceEpoch, c.zoom);
    _notify();
  }

  Future<void> focusAt(Offset p) async => controls?.focusAt(p);

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _wantOpen = false;
    settings.removeListener(_onSettings);
    _lifecycle.dispose();
    // 카메라를 다 닫은 뒤에 알림 객체들을 정리(화면마다 파이프라인을 새로 만들므로 쌓이지 않게)
    _serial(_close).whenComplete(() {
      for (final n in <ChangeNotifier>[
        detections,
        metrics,
        ai,
        hazardShift,
        hazardAnchored,
        hazardRevision,
        hand,
        isDark,
      ]) {
        n.dispose();
      }
    });
    super.dispose();
  }
}
