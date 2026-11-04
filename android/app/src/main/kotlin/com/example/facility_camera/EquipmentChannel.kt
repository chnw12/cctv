package com.example.facility_camera

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import ai.onnxruntime.TensorInfo
import android.content.Context
import android.graphics.BitmapFactory
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.nio.FloatBuffer
import java.util.concurrent.Executors
import kotlin.math.max
import kotlin.math.min

/**
 * 설비 전용 탐지기(YOLO 계열 ONNX, assets/equipment.onnx) 채널. ONNX Runtime CPU로 추론.
 * assets/equipment_labels.txt: 모델 출력 번호마다 한 줄 "앱 설비 번호 표현"(YOLOE는 한 설비를 여러 표현으로 찾음).
 * Dart가 똑바로 세우고 줄인 RGBA를 주면 모델 입력 크기로 레터박스(비율 유지 + 회색 여백) → 추론 →
 * 점수 거르기·겹침 제거(NMS) → 박스마다 [l, t, r, b, 점수, 클래스](똑바로 선 화면 기준 0..1)를 돌려줌.
 * 출력 두 형식을 다 읽음: YOLO11/YOLOE [1, 4+클래스(+마스크32), 앵커] (cx, cy, w, h),
 * 끝단 NMS [1, 300, 6(+32)] (x1, y1, x2, y2, 점수, 클래스). 좌표가 1.5를 넘으면 입력 픽셀로 봄(ONNX), 아니면 0..1.
 */
class EquipmentChannel(private val context: Context, messenger: BinaryMessenger) {
    private val exec = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val env: OrtEnvironment by lazy { OrtEnvironment.getEnvironment() }
    private var session: OrtSession? = null
    private var inputName = ""
    private var outputName = ""
    private var input: FloatBuffer? = null
    private var inW = 0
    private var inH = 0
    private var classMap = IntArray(0)

    init {
        MethodChannel(messenger, "facility_camera/equipment").setMethodCallHandler { call, result ->
            when (call.method) {
                "detect" -> {
                    val path = call.argument<String>("path")
                    val size = call.argument<Int>("size") ?: 480
                    val rgba = call.argument<ByteArray>("rgba")
                    val w = call.argument<Int>("w") ?: 0
                    val h = call.argument<Int>("h") ?: 0
                    val minConf = call.argument<Double>("minConf")?.toFloat() ?: 0.25f
                    if (path == null && (rgba == null || w <= 0 || h <= 0 || rgba.size < w * h * 4)) {
                        result.error("bad_args", "rgba/w/h 이상", null)
                        return@setMethodCallHandler
                    }
                    exec.execute {
                        val out = try {
                            if (path != null) {
                                val (img, iw, ih) = readImage(path, size)
                                Result.success(detect(img, iw, ih, minConf))
                            } else {
                                Result.success(detect(rgba!!, w, h, minConf))
                            }
                        } catch (t: Throwable) {
                            Log.e("EquipmentChannel", "설비 탐지 실패", t)
                            Result.failure(t)
                        }
                        main.post {
                            out.fold(
                                { result.success(it) },
                                { result.error("equipment_failed", it.toString(), null) })
                        }
                    }
                }
                "close" -> {
                    exec.execute {
                        session?.close()
                        session = null
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun session(): OrtSession = session ?: run {
        // CPU 4스레드. 설비 탐지기를 쓰는 동안 ML Kit은 안 돌아서 CPU를 다 써도 됨
        val opts = OrtSession.SessionOptions().apply {
            setIntraOpNumThreads(4)
            setOptimizationLevel(OrtSession.SessionOptions.OptLevel.ALL_OPT)
        }
        val s = env.createSession(context.assets.open(MODEL).use { it.readBytes() }, opts)
        inputName = s.inputNames.first()
        outputName = s.outputNames.first() // 마스크(output1)는 안 씀
        val shape = (s.inputInfo.getValue(inputName).info as TensorInfo).shape // [1, 3, H, W]
        inH = shape[2].toInt()
        inW = shape[3].toInt()
        input = FloatBuffer.allocate(3 * inW * inH)
        classMap = try {
            context.assets.open(LABELS).bufferedReader().readLines()
                .filter { it.isNotBlank() }
                .map { it.trim().substringBefore(' ').toInt() }
                .toIntArray()
        } catch (e: Exception) {
            IntArray(0) // 라벨 파일이 없으면 출력 번호 = 설비 번호
        }
        Log.i("EquipmentChannel", "모델 입력 ${shape.contentToString()} 클래스 ${classMap.size}")
        s.also { session = it }
    }

    private fun detect(rgba: ByteArray, w: Int, h: Int, minConf: Float): Map<String, Any> {
        val s = session()
        val buf = input!!
        // 레터박스: 비율 유지로 줄이고 남는 곳은 회색(114, 학습 때와 같게). ONNX 입력은 채널별 평면(NCHW)
        val scale = min(inW.toFloat() / w, inH.toFloat() / h)
        val nw = (w * scale).toInt()
        val nh = (h * scale).toInt()
        val px = (inW - nw) / 2
        val py = (inH - nh) / 2
        val plane = inW * inH
        val arr = buf.array()
        val gray = 114f / 255f
        for (y in 0 until inH) {
            val sy = ((y - py) / scale).toInt()
            for (x in 0 until inW) {
                val sx = ((x - px) / scale).toInt()
                val i = y * inW + x
                if (x < px || x >= px + nw || y < py || y >= py + nh || sx >= w || sy >= h) {
                    arr[i] = gray; arr[plane + i] = gray; arr[2 * plane + i] = gray
                } else {
                    val o = (sy * w + sx) * 4
                    arr[i] = (rgba[o].toInt() and 0xff) / 255f
                    arr[plane + i] = (rgba[o + 1].toInt() and 0xff) / 255f
                    arr[2 * plane + i] = (rgba[o + 2].toInt() and 0xff) / 255f
                }
            }
        }
        buf.rewind()
        val t0 = SystemClock.elapsedRealtime()
        @Suppress("UNCHECKED_CAST")
        val o = OnnxTensor.createTensor(env, buf, longArrayOf(1, 3, inH.toLong(), inW.toLong())).use { x ->
            s.run(mapOf(inputName to x), setOf(outputName)).use { res ->
                (res[0].value as Array<Array<FloatArray>>)[0]
            }
        }
        val ms = SystemClock.elapsedRealtime() - t0

        // 입력 기준 좌표 → 레터박스를 빼고 똑바로 선 화면 기준 0..1
        val cand = ArrayList<FloatArray>()
        fun add(x1: Float, y1: Float, x2: Float, y2: Float, pixels: Boolean, score: Float, cls: Int) {
            val fx = if (pixels) 1f else inW.toFloat()
            val fy = if (pixels) 1f else inH.toFloat()
            val l = (x1 * fx - px) / nw
            val t = (y1 * fy - py) / nh
            val r = (x2 * fx - px) / nw
            val b = (y2 * fy - py) / nh
            val c = if (cls in classMap.indices) classMap[cls] else cls
            if (r > l && b > t) cand.add(floatArrayOf(l, t, r, b, score, c.toFloat()))
        }
        val rows = o.size
        val cols = o[0].size
        if (rows < cols) {
            // [4+nc(+32), 앵커]: 마스크 계수(32)는 안 씀
            val nc = if (classMap.isNotEmpty()) classMap.size else rows - 4
            val pixels = o[2].max() > 1.5f
            for (a in 0 until cols) {
                var best = 0
                var score = 0f
                for (c in 0 until nc) {
                    val v = o[4 + c][a]
                    if (v > score) { score = v; best = c }
                }
                if (score < minConf) continue
                val cx = o[0][a]; val cy = o[1][a]; val bw = o[2][a]; val bh = o[3][a]
                add(cx - bw / 2, cy - bh / 2, cx + bw / 2, cy + bh / 2, pixels, score, best)
            }
        } else {
            // [300, 6(+32)]: 이미 NMS 됨
            for (row in o) {
                if (row[4] < minConf) continue
                add(row[0], row[1], row[2], row[3], max(row[2], row[3]) > 1.5f, row[4], row[5].toInt())
            }
        }
        val kept = nms(cand)
        return mapOf(
            "delegate" to "cpu",
            "ms" to ms,
            "boxes" to kept.flatMap { b -> b.map { it.toDouble() } },
        )
    }

    /** 테스트 이미지(사진 파일): 긴 변이 size 이상 남게 2배씩 줄여 읽고 RGBA로 */
    private fun readImage(path: String, size: Int): Triple<ByteArray, Int, Int> {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, bounds)
        var sample = 1
        while (max(bounds.outWidth, bounds.outHeight) / (sample * 2) >= size) sample *= 2
        val bmp = BitmapFactory.decodeFile(path, BitmapFactory.Options().apply { inSampleSize = sample })
            ?: throw IllegalArgumentException("사진을 읽을 수 없음: $path")
        val w = bmp.width
        val h = bmp.height
        val px = IntArray(w * h)
        bmp.getPixels(px, 0, w, 0, 0, w, h)
        bmp.recycle()
        val out = ByteArray(w * h * 4)
        for (i in px.indices) {
            val c = px[i]
            out[i * 4] = (c shr 16).toByte()
            out[i * 4 + 1] = (c shr 8).toByte()
            out[i * 4 + 2] = c.toByte()
            out[i * 4 + 3] = (c ushr 24).toByte()
        }
        return Triple(out, w, h)
    }

    /** 클래스 상관없이 겹침 제거(배관·덕트처럼 비슷한 설비가 같은 자리에 두 번 잡히면 추적기에 중복 ID가 생김) */
    private fun nms(boxes: List<FloatArray>): List<FloatArray> {
        val sorted = boxes.sortedByDescending { it[4] }
        val kept = ArrayList<FloatArray>()
        for (b in sorted) {
            if (kept.size >= MAX_BOXES) break
            if (kept.none { iou(it, b) > NMS_IOU }) kept.add(b)
        }
        return kept
    }

    private fun iou(a: FloatArray, b: FloatArray): Float {
        val iw = min(a[2], b[2]) - max(a[0], b[0])
        val ih = min(a[3], b[3]) - max(a[1], b[1])
        if (iw <= 0 || ih <= 0) return 0f
        val inter = iw * ih
        return inter / ((a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter)
    }

    companion object {
        const val MODEL = "equipment.onnx"
        const val LABELS = "equipment_labels.txt"
        const val NMS_IOU = 0.5f
        const val MAX_BOXES = 20
    }
}
