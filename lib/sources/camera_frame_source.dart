import 'dart:async';
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import '../core/jpeg.dart';
import '../core/frame.dart';
import '../motion/camera_motion.dart';
import 'frame_source.dart';

class CameraFrameSource implements FrameSource, CameraControls {
  /// 미리보기·분석·촬영이 같은 해상도를 씁니다(camera 플러그인 제약).
  /// 높을수록 AI 스냅샷은 선명하지만 프레임마다 넘기는 바이트가 커집니다.
  CameraFrameSource({this.preset = ResolutionPreset.high, this.fps = 15});
  final ResolutionPreset preset;

  /// 카메라 프레임레이트 상한. 플러그인은 처리 못 하고 버릴 프레임까지 매번 NV21로 변환·전송하므로
  /// 처리 속도 근처로 낮추면 그만큼 CPU가 탐지에 돌아갑니다. null = 기기 기본(보통 30)
  final int? fps;

  CameraController? _c;
  Size? _lensFov;

  static const _info = MethodChannel('facility_camera/camera_info');

  /// 이름 = Camera2 카메라 ID(CameraX 플러그인). 채널이 없거나(테스트) 값이 없으면 null
  static Future<Size?> _readLensFov(
      String id, Size stream, bool rotated) async {
    try {
      final m = await _info.invokeMapMethod<String, double>('lens', id);
      if (m == null) return null;
      return LensFov.portrait(
          focalMm: m['focalMm'] ?? 0,
          sensorWMm: m['sensorWMm'] ?? 0,
          sensorHMm: m['sensorHMm'] ?? 0,
          streamW: stream.width,
          streamH: stream.height,
          rotated: rotated);
    } catch (_) {
      return null;
    }
  }

  @override
  Size? get lensFov => _lensFov;
  final _out = StreamController<Frame>.broadcast();
  final _aspect = ValueNotifier<double>(9 / 16);

  @override
  String get name => '폰 카메라';
  @override
  ValueListenable<double> get aspectRatio => _aspect;
  @override
  Stream<Frame> get frames => _out.stream;

  @override
  Future<void> start() async {
    final cams = await availableCameras();
    final back = cams.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cams.first,
    );
    final c = CameraController(
      back,
      preset,
      enableAudio: false,
      fps: fps,
      imageFormatGroup: Platform.isAndroid
          ? ImageFormatGroup.nv21
          : ImageFormatGroup.bgra8888,
    );
    await c.initialize();
    await c.lockCaptureOrientation(DeviceOrientation.portraitUp);
    _c = c;
    try {
      _minZoom = await c.getMinZoomLevel();
      _maxZoom = await c.getMaxZoomLevel();
    } catch (_) {
      // 줌 정보를 못 주는 카메라: 1배 고정
    }
    try {
      _maxEv = await c.getMaxExposureOffset();
    } catch (_) {
      // 노출 보정 미지원: 0 고정
    }

    final ps = c.value.previewSize!; // 가로형(큰 값이 width)
    _aspect.value = ps.height / ps.width; // 세로 고정이므로 뒤집어서 사용

    final sensor = back.sensorOrientation; // 세로 고정 + 후면 카메라 → 센서 각도 그대로
    _lensFov = await _readLensFov(back.name, ps, sensor == 90 || sensor == 270);
    await c.startImageStream((CameraImage img) {
      final rotated = sensor == 90 || sensor == 270;
      final w = img.width.toDouble(), h = img.height.toDouble();
      _out.add(Frame.raw(
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        format: Platform.isAndroid ? FrameFormat.nv21 : FrameFormat.bgra8888,
        bytes: img.planes.first.bytes,
        rawSize: Size(w, h),
        rotationDegrees: sensor,
        bytesPerRow: img.planes.first.bytesPerRow,
        uprightSize: rotated ? Size(h, w) : Size(w, h),
      ));
    });
  }

  @override
  Future<void> stop() async {
    final c = _c;
    if (c != null && c.value.isStreamingImages) {
      await c.stopImageStream();
    }
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _c?.dispose();
    _c = null;
    await _out.close();
    _aspect.dispose();
  }

  @override
  Future<Uint8List> snapshotJpeg() async {
    final c = _c;
    if (c == null || !c.value.isInitialized) throw StateError('카메라 준비 안 됨');
    // CameraX는 미리보기·분석·촬영을 함께 바인딩하므로 스트림을 멈추지 않고 찍을 수 있음
    final shot = await c.takePicture();
    try {
      return await shrinkJpeg(shot.path);
    } finally {
      File(shot.path).delete().ignore();
    }
  }

  @override
  Widget buildPreview(BuildContext context) {
    final c = _c;
    if (c == null || !c.value.isInitialized) return const SizedBox.shrink();
    return CameraPreview(c);
  }

  // ── 카메라 조작 ──
  bool _torch = false;
  double _minZoom = 1, _maxZoom = 1, _zoom = 1, _maxEv = 0;

  @override
  CameraControls get controls => this;
  @override
  bool get torchOn => _torch;
  @override
  double get minZoom => _minZoom;
  @override
  double get maxZoom => _maxZoom;
  @override
  double get zoom => _zoom;

  CameraController get _ready {
    final c = _c;
    if (c == null || !c.value.isInitialized) throw StateError('카메라 준비 안 됨');
    return c;
  }

  @override
  Future<void> setTorch(bool on) async {
    await _ready.setFlashMode(on ? FlashMode.torch : FlashMode.off);
    _torch = on;
  }

  @override
  Future<void> setZoom(double zoom) async {
    final z = zoom.clamp(_minZoom, _maxZoom).toDouble();
    await _ready.setZoomLevel(z);
    _zoom = z;
  }

  @override
  double get maxExposureOffset => _maxEv;

  @override
  Future<void> setExposureOffset(double ev) async {
    if (_maxEv <= 0) return;
    await _ready.setExposureOffset(ev.clamp(0, _maxEv).toDouble());
  }

  @override
  Future<void> focusAt(Offset point) async {
    final c = _ready;
    final p = Offset(point.dx.clamp(0, 1), point.dy.clamp(0, 1));
    await c.setFocusPoint(p);
    await c.setExposurePoint(p);
  }
}
