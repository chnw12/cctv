import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import '../core/frame.dart';

/// 입력 통일 인터페이스. 오즈모(USB 웹캠)는 이걸 구현한 클래스만 추가하면 됩니다.
abstract class FrameSource {
  String get name;

  /// 똑바로 선 화면 기준 가로/세로 비율 (start() 이후 유효, 이미지마다 바뀔 수 있음)
  ValueListenable<double> get aspectRatio;

  Stream<Frame> get frames;

  Future<void> start();
  Future<void> stop();
  Future<void> dispose();

  /// AI 분석용 현재 장면 JPEG (긴 변 ~1024px, 똑바로 선 방향)
  Future<Uint8List> snapshotJpeg();

  /// 화면에 깔 배경(카메라 미리보기 또는 테스트 이미지)
  Widget buildPreview(BuildContext context);

  /// 플래시·줌·초점 조작. 지원하지 않는 입력(테스트 이미지)은 null
  CameraControls? get controls;
}

/// 실제 카메라 조작. 기기·에뮬레이터마다 지원이 달라 실패하면 예외를 던집니다(화면에서 안내).
abstract class CameraControls {
  bool get torchOn;

  /// 기계실은 어두운 곳이 많아 손전등 모드가 필요
  Future<void> setTorch(bool on);

  double get minZoom;
  double get maxZoom;
  double get zoom;
  Future<void> setZoom(double zoom);

  /// 미리보기 기준 0..1 좌표에 초점·노출 맞추기
  Future<void> focusAt(Offset point);

  /// 노출 보정(EV). 어두운 곳에서 밝게. 지원 범위 밖은 잘라서 적용
  double get maxExposureOffset;
  Future<void> setExposureOffset(double ev);

  /// 렌즈 값(초점거리·센서 크기)으로 계산한 세로 화면 기준 (가로, 세로) 화각(rad).
  /// 자이로 회전각 → 화면 이동량 환산의 기준. 모르면 null(보통 폰 값 + 온라인 보정)
  Size? get lensFov;
}
