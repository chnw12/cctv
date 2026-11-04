package com.example.facility_camera

import android.content.Context
import android.graphics.Bitmap
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.google.mediapipe.framework.image.BitmapImageBuilder
import com.google.mediapipe.tasks.core.BaseOptions
import com.google.mediapipe.tasks.core.Delegate
import com.google.mediapipe.tasks.vision.core.RunningMode
import com.google.mediapipe.tasks.vision.handlandmarker.HandLandmarker
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import java.util.concurrent.Executors

/**
 * 손 관절점 인식(MediaPipe Hand Landmarker) 채널. AR: 화면 속 손가락으로 위험 박스를 누르기.
 * Dart가 똑바로 세우고 줄인 RGBA 프레임을 주면 손마다 관절점 21개(0..1 정규화 x, y, z)를 돌려줌.
 * 모델은 처음 쓸 때 assets/hand_landmarker.task 에서 읽고, 인식은 따로 스레드 하나에서(화면 안 멈추게).
 */
class HandChannel(private val context: Context, messenger: BinaryMessenger) {
    private val exec = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var landmarker: HandLandmarker? = null
    private var lastTs = -1L
    private var gpu = false

    init {
        MethodChannel(messenger, "facility_camera/hands").setMethodCallHandler { call, result ->
            when (call.method) {
                "detect" -> {
                    val rgba = call.argument<ByteArray>("rgba")
                    val w = call.argument<Int>("w") ?: 0
                    val h = call.argument<Int>("h") ?: 0
                    val ts = call.argument<Number>("ts")?.toLong() ?: 0L
                    if (rgba == null || w <= 0 || h <= 0 || rgba.size < w * h * 4) {
                        result.error("bad_args", "rgba/w/h 이상", null)
                        return@setMethodCallHandler
                    }
                    exec.execute {
                        // 네이티브 라이브러리 로드 실패(UnsatisfiedLinkError)도 앱을 죽이지 않게 Throwable까지
                        val out = try {
                            Result.success(detect(rgba, w, h, ts))
                        } catch (t: Throwable) {
                            Log.e("HandChannel", "손 인식 실패", t) // 원인(예: 코드 줄이기로 빠진 클래스) 확인용
                            Result.failure(t)
                        }
                        main.post {
                            out.fold(
                                { result.success(it) },
                                { result.error("hand_failed", it.toString(), null) })
                        }
                    }
                }
                "close" -> {
                    exec.execute {
                        landmarker?.close()
                        landmarker = null
                        lastTs = -1L
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun create(delegate: Delegate): HandLandmarker = HandLandmarker.createFromOptions(
        context,
        HandLandmarker.HandLandmarkerOptions.builder()
            .setBaseOptions(
                BaseOptions.builder()
                    .setModelAssetPath("hand_landmarker.task")
                    .setDelegate(delegate)
                    .build()
            )
            .setRunningMode(RunningMode.VIDEO)
            .setNumHands(2)
            .setMinHandDetectionConfidence(0.5f)
            .setMinHandPresenceConfidence(0.5f)
            .setMinTrackingConfidence(0.5f)
            .build()
    )

    /** GPU 먼저(구글 픽셀 6 기준 CPU 17ms → GPU 12ms, 물체 탐지가 쓰는 CPU와 안 다툼), 안 되면 CPU */
    private fun landmarker(): HandLandmarker = landmarker ?: try {
        create(Delegate.GPU).also { gpu = true }
    } catch (t: Throwable) {
        Log.w("HandChannel", "GPU 손 인식 불가, CPU로: $t")
        create(Delegate.CPU).also { gpu = false }
    }.also { landmarker = it }

    /**
     * {"gpu": GPU로 돌았나, "hands": 손마다 [x0, y0, z0, x1, ...] 63개}.
     * VIDEO 모드는 시각이 늘어나야 해서 같거나 이전 시각이면 1ms 뒤로.
     * GPU가 만들어지긴 했는데 인식에서 실패하는 기기도 있어 그때는 CPU로 바꿔 한 번 더
     */
    private fun detect(rgba: ByteArray, w: Int, h: Int, ts: Long): Map<String, Any> {
        val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        bmp.copyPixelsFromBuffer(ByteBuffer.wrap(rgba, 0, w * h * 4))
        val image = BitmapImageBuilder(bmp).build()
        fun run(): List<List<Double>> {
            val t = if (ts > lastTs) ts else lastTs + 1
            lastTs = t
            return landmarker().detectForVideo(image, t).landmarks().map { hand ->
                hand.flatMap { p -> listOf(p.x().toDouble(), p.y().toDouble(), p.z().toDouble()) }
            }
        }
        val hands = try {
            run()
        } catch (t: Throwable) {
            if (!gpu) throw t
            Log.w("HandChannel", "GPU 인식 실패, CPU로 다시: $t")
            landmarker?.close()
            landmarker = create(Delegate.CPU)
            gpu = false
            run()
        }
        bmp.recycle()
        return mapOf("gpu" to gpu, "hands" to hands)
    }
}
