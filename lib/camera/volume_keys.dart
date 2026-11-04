import 'package:flutter/services.dart';

/// 볼륨 키를 버튼으로 쓰기(장갑 낀 현장용). 안드로이드 MainActivity가 가로채 이 채널로 알려 줍니다.
/// 켜 둔 동안에는 시스템 음량이 바뀌지 않으니, 필요한 화면에서만 켜고 바로 끄세요.
/// 안드로이드가 아니거나 테스트 환경이면 조용히 아무것도 하지 않습니다.
class VolumeKeys {
  static const _channel = MethodChannel('facility_camera/volume_keys');
  static void Function()? _onPressed;

  static Future<void> listen(void Function() onPressed) async {
    _onPressed = onPressed;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'pressed') _onPressed?.call();
    });
    await _set(true);
  }

  static Future<void> stop() async {
    _onPressed = null;
    await _set(false);
  }

  static Future<void> _set(bool on) async {
    try {
      await _channel.invokeMethod('setIntercept', on);
    } on MissingPluginException {
      // 안드로이드 외 플랫폼·위젯 테스트
    } on PlatformException {
      // 무시: 볼륨 키 없이도 화면 버튼으로 동작
    }
  }
}
