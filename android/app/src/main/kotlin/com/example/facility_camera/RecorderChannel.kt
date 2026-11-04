package com.example.facility_camera

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageFormat
import android.graphics.Matrix
import android.graphics.Rect
import android.graphics.YuvImage
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.Executors
import kotlin.math.max
import kotlin.math.min

/**
 * 시험용 녹화·재생 채널. 카메라 원본(NV21, 센서 방향 그대로)을 JPEG 파일로 저장하고,
 * 재생할 때는 그 JPEG를 다시 NV21로 풀어 진짜 카메라 프레임처럼 넘김(탐지·추적·손 인식이 실제와 같은 길로 돎).
 * - saveJpeg {nv21, w, h, stride, path, quality}: 저장(따로 스레드, 화면 안 멈추게)
 * - loadNv21 {path}: JPEG → NV21 {bytes, w, h}(가로·세로는 짝수로 자름)
 * - uprightJpeg {path, rotation, maxSide, quality}: 똑바로 세우고 줄인 JPEG(AI 점검 사진)
 */
class RecorderChannel(messenger: BinaryMessenger) {
    private val saver = Executors.newSingleThreadExecutor()
    private val loader = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    init {
        MethodChannel(messenger, "facility_camera/recorder").setMethodCallHandler { call, result ->
            fun <T> run(exec: java.util.concurrent.Executor, work: () -> T) = exec.execute {
                val out = try {
                    Result.success(work())
                } catch (t: Throwable) {
                    Log.e("RecorderChannel", "${call.method} 실패", t)
                    Result.failure(t)
                }
                main.post {
                    out.fold({ result.success(it) }, { result.error("recorder_failed", it.toString(), null) })
                }
            }
            when (call.method) {
                "saveJpeg" -> {
                    val nv21 = call.argument<ByteArray>("nv21")
                    val w = call.argument<Int>("w") ?: 0
                    val h = call.argument<Int>("h") ?: 0
                    val stride = call.argument<Int>("stride") ?: w
                    val path = call.argument<String>("path")
                    val quality = call.argument<Int>("quality") ?: 80
                    if (nv21 == null || path == null || w <= 0 || h <= 0) {
                        result.error("bad_args", "nv21/w/h/path 이상", null)
                        return@setMethodCallHandler
                    }
                    run(saver) { saveJpeg(nv21, w, h, stride, path, quality) }
                }
                "loadNv21" -> {
                    val path = call.argument<String>("path")
                    if (path == null) {
                        result.error("bad_args", "path 없음", null)
                        return@setMethodCallHandler
                    }
                    run(loader) { loadNv21(path) }
                }
                "uprightJpeg" -> {
                    val path = call.argument<String>("path")
                    val rotation = call.argument<Int>("rotation") ?: 0
                    val maxSide = call.argument<Int>("maxSide") ?: 1024
                    val quality = call.argument<Int>("quality") ?: 80
                    if (path == null) {
                        result.error("bad_args", "path 없음", null)
                        return@setMethodCallHandler
                    }
                    run(loader) { uprightJpeg(path, rotation, maxSide, quality) }
                }
                else -> result.notImplemented()
            }
        }
    }

    /** 저장한 파일 크기(바이트) */
    private fun saveJpeg(nv21: ByteArray, w: Int, h: Int, stride: Int, path: String, quality: Int): Int {
        val f = File(path)
        f.parentFile?.mkdirs()
        val img = YuvImage(nv21, ImageFormat.NV21, w, h, if (stride != w) intArrayOf(stride, stride) else null)
        FileOutputStream(f).use { img.compressToJpeg(Rect(0, 0, w, h), quality, it) }
        return f.length().toInt()
    }

    private fun loadNv21(path: String): Map<String, Any> {
        val bmp = BitmapFactory.decodeFile(path) ?: throw IllegalArgumentException("사진을 읽을 수 없음: $path")
        val w = bmp.width and 1.inv()
        val h = bmp.height and 1.inv()
        val px = IntArray(w * h)
        bmp.getPixels(px, 0, w, 0, 0, w, h)
        bmp.recycle()
        // BT.601(카메라 NV21과 같은 식): 밝기 전체 + 2x2마다 색(V, U 순서)
        val out = ByteArray(w * h * 3 / 2)
        var uv = w * h
        for (y in 0 until h) {
            for (x in 0 until w) {
                val c = px[y * w + x]
                val r = (c shr 16) and 0xff
                val g = (c shr 8) and 0xff
                val b = c and 0xff
                out[y * w + x] = (((66 * r + 129 * g + 25 * b + 128) shr 8) + 16).coerceIn(0, 255).toByte()
                if (y and 1 == 0 && x and 1 == 0) {
                    out[uv++] = (((112 * r - 94 * g - 18 * b + 128) shr 8) + 128).coerceIn(0, 255).toByte()
                    out[uv++] = (((-38 * r - 74 * g + 112 * b + 128) shr 8) + 128).coerceIn(0, 255).toByte()
                }
            }
        }
        return mapOf("bytes" to out, "w" to w, "h" to h)
    }

    private fun uprightJpeg(path: String, rotation: Int, maxSide: Int, quality: Int): ByteArray {
        val bmp = BitmapFactory.decodeFile(path) ?: throw IllegalArgumentException("사진을 읽을 수 없음: $path")
        val s = min(1f, maxSide.toFloat() / max(bmp.width, bmp.height))
        val m = Matrix().apply {
            postScale(s, s)
            postRotate(rotation.toFloat())
        }
        val up = Bitmap.createBitmap(bmp, 0, 0, bmp.width, bmp.height, m, true)
        val out = ByteArrayOutputStream()
        up.compress(Bitmap.CompressFormat.JPEG, quality, out)
        if (up !== bmp) up.recycle()
        bmp.recycle()
        return out.toByteArray()
    }
}
