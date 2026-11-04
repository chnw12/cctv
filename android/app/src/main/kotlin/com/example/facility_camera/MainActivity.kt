package com.example.facility_camera

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.view.KeyEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 1) 볼륨 키를 "AI 점검" 버튼으로 쓰기 위한 처리.
 * Flutter 기본 임베딩은 볼륨 키를 Dart로 넘기지 않고 시스템 음량 조절로 보내므로(에뮬레이터에서 확인),
 * 점검 화면이 켜 달라고 할 때만 여기서 가로채 채널로 알립니다. 그 외에는 평소처럼 음량 조절.
 * 2) 카메라 렌즈 값(초점거리·센서 크기). camera 플러그인이 안 알려 줘서 화각 계산용으로 직접 읽음.
 * 3) 앱 기록 머리말: 기기·버전과 지난번에 앱이 왜 꺼졌는지(충돌·메모리 부족 등, 안드로이드 11 이상).
 */
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var interceptVolume = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "facility_camera/volume_keys").apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "setIntercept" -> {
                        interceptVolume = call.arguments as? Boolean ?: false
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
        HandChannel(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
        EquipmentChannel(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
        RecorderChannel(flutterEngine.dartExecutor.binaryMessenger)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "facility_camera/camera_info")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "lens" -> result.success(lensInfo(call.arguments as? String ?: "0"))
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "facility_camera/app_info")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startInfo" -> result.success(startInfo())
                    else -> result.notImplemented()
                }
            }
    }

    private fun startInfo(): Map<String, Any?> {
        val pkg = packageManager.getPackageInfo(packageName, 0)
        val exits = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            (getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager)
                .getHistoricalProcessExitReasons(packageName, 0, 5)
                .map {
                    mapOf(
                        "time" to it.timestamp,
                        "reason" to exitReason(it.reason),
                        "desc" to (it.description ?: ""),
                        "rssKb" to it.rss,
                    )
                }
        } else emptyList()
        return mapOf(
            "model" to "${Build.MANUFACTURER} ${Build.MODEL}",
            "android" to Build.VERSION.RELEASE,
            "sdk" to Build.VERSION.SDK_INT,
            "version" to pkg.versionName,
            "build" to if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) pkg.longVersionCode else 0L,
            "exits" to exits,
        )
    }

    /** 안드로이드가 알려 주는 종료 이유를 사람이 읽을 이름으로 */
    private fun exitReason(r: Int): String = when (r) {
        ApplicationExitInfo.REASON_CRASH -> "충돌(자바·코틀린)"
        ApplicationExitInfo.REASON_CRASH_NATIVE -> "충돌(네이티브)"
        ApplicationExitInfo.REASON_ANR -> "응답 없음(ANR)"
        ApplicationExitInfo.REASON_LOW_MEMORY -> "메모리 부족"
        ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE -> "자원 과다 사용"
        ApplicationExitInfo.REASON_INITIALIZATION_FAILURE -> "시작 실패"
        ApplicationExitInfo.REASON_SIGNALED -> "시스템이 종료"
        ApplicationExitInfo.REASON_EXIT_SELF -> "앱이 스스로 종료"
        ApplicationExitInfo.REASON_USER_REQUESTED -> "사용자가 종료(최근 앱에서 밀기 등)"
        ApplicationExitInfo.REASON_USER_STOPPED -> "사용자가 강제 중지"
        ApplicationExitInfo.REASON_PERMISSION_CHANGE -> "권한 변경"
        ApplicationExitInfo.REASON_DEPENDENCY_DIED -> "연결된 프로세스 종료"
        ApplicationExitInfo.REASON_OTHER -> "기타"
        14 -> "시스템이 얼림(freezer)" // REASON_FREEZER(API 33)
        15 -> "앱 상태 변경(비활성화 등)" // REASON_PACKAGE_STATE_CHANGE(API 34)
        16 -> "앱 업데이트(새로 설치)" // REASON_PACKAGE_UPDATED(API 34)
        else -> "알 수 없음($r)"
    }

    /** 영상이 실제로 나오는 영역(active array)의 센서 크기(mm)와 초점거리. 못 읽으면 null(기본 화각 사용) */
    private fun lensInfo(cameraId: String): Map<String, Double>? = try {
        val ch = (getSystemService(Context.CAMERA_SERVICE) as CameraManager)
            .getCameraCharacteristics(cameraId)
        val focal = ch.get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)?.firstOrNull()
        val size = ch.get(CameraCharacteristics.SENSOR_INFO_PHYSICAL_SIZE)
        val pixels = ch.get(CameraCharacteristics.SENSOR_INFO_PIXEL_ARRAY_SIZE)
        val active = ch.get(CameraCharacteristics.SENSOR_INFO_ACTIVE_ARRAY_SIZE)
        if (focal == null || size == null || pixels == null || active == null) null
        else mapOf(
            "focalMm" to focal.toDouble(),
            "sensorWMm" to size.width.toDouble() * active.width() / pixels.width,
            "sensorHMm" to size.height.toDouble() * active.height() / pixels.height,
        )
    } catch (e: Exception) {
        null
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        val code = event.keyCode
        if (interceptVolume && (code == KeyEvent.KEYCODE_VOLUME_DOWN || code == KeyEvent.KEYCODE_VOLUME_UP)) {
            // 길게 눌러 반복되는 이벤트는 무시(한 번 누르면 한 번만)
            if (event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0) {
                channel?.invokeMethod("pressed", if (code == KeyEvent.KEYCODE_VOLUME_UP) "up" else "down")
            }
            return true
        }
        return super.dispatchKeyEvent(event)
    }
}
