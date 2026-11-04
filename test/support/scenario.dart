import 'dart:math' as math;
import 'dart:ui';
import 'package:facility_camera/core/frame.dart';
import 'package:facility_camera/detection/detector.dart';
import 'package:facility_camera/motion/camera_motion.dart';

/// 자율주행 인지 테스트처럼 "정답(ground truth)이 있는 합성 장면"을 만들어
/// 추적기를 돌리고 MOT 지표(ID 전환 등)를 잽니다. 실제 탐지기의 약점
/// (놓침·떨림·오탐·불규칙한 처리 간격)을 확률로 흉내 냅니다.

/// 정답 물체 하나: 시각 t(초) → 박스, 보이는지
class GtObject {
  GtObject(this.boxAt, {bool Function(double t)? visible})
      : visible = visible ?? ((_) => true);
  final Rect Function(double t) boxAt;
  final bool Function(double t) visible;
}

class Scenario {
  Scenario({
    required this.name,
    required this.objects,
    required this.frameTimesMs,
    this.missProb = 0,
    this.jitter = 0,
    this.falsePosProb = 0,
    this.scaleJitter = 0,
    this.dupProb = 0,
    this.seed = 1,
    this.cameraShift,
    this.needsGyro = false,
    this.maxIdSwitches = 0,
  });

  final String name;
  final List<GtObject> objects;
  final List<int> frameTimesMs;

  /// 실제 물체를 한 프레임 놓칠 확률
  final double missProb;

  /// 박스 가장자리 떨림 표준편차(박스 크기 대비 비율)
  final double jitter;

  /// 프레임마다 엉뚱한 곳에 오탐 박스가 하나 생길 확률
  final double falsePosProb;

  /// 박스 전체 크기 떨림 표준편차(비율). 실기기 ML Kit은 같은 물체도 프레임마다 크기가 꽤 달라짐
  final double scaleJitter;

  /// 같은 물체의 일부(45~75% 크기)를 박스로 하나 더 내놓을 확률(실기기에서 물체 수가 1↔2로 깜빡이던 것)
  final double dupProb;
  final int seed;

  /// 카메라(폰) 움직임 때문에 정지 물체가 화면에서 누적으로 밀린 양(정답).
  /// 있으면 이것으로 가짜 자이로 신호를 만듭니다. objects의 박스에는 이미 반영돼 있어야 함
  final Offset Function(double t)? cameraShift;

  /// 자이로 없이는 원리상 풀 수 없는 상황(자율주행 시나리오 목록의 "필요 센서"처럼 표시).
  /// 예: 등간격 설비 + 프레임당 이동이 간격에 가까움 → 박스만으로는 왼쪽·오른쪽 이동이 구분 안 됨(앨리어싱)
  final bool needsGyro;

  /// 허용하는 ID 전환 수(기본 0). 아주 거친 시나리오에서 "다른 물체와 뒤바뀜"이 아니라
  /// 한 물체가 새 번호를 한 번 받는 정도는 허용할 때
  final int maxIdSwitches;

  List<SimFrame> simulate() {
    final rnd = math.Random(seed);
    double gauss() {
      // Box–Muller
      final u1 = 1 - rnd.nextDouble(), u2 = rnd.nextDouble();
      return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2);
    }

    return [
      for (final ms in frameTimesMs)
        () {
          final t = ms / 1000;
          final boxes = <Rect>[], gt = <int>[];
          for (var o = 0; o < objects.length; o++) {
            if (!objects[o].visible(t) || rnd.nextDouble() < missProb) continue;
            final b0 = objects[o].boxAt(t);
            final k = (1 + scaleJitter * gauss()).clamp(0.5, 1.6);
            final b = Rect.fromCenter(
                center: b0.center, width: b0.width * k, height: b0.height * k);
            final s = jitter * (b.width + b.height) / 2;
            boxes.add(Rect.fromLTRB(b.left + s * gauss(), b.top + s * gauss(),
                b.right + s * gauss(), b.bottom + s * gauss()));
            gt.add(o);
            if (rnd.nextDouble() < dupProb) {
              final f = 0.45 + 0.3 * rnd.nextDouble();
              final w = b0.width * f, h = b0.height * f;
              boxes.add(Rect.fromLTWH(
                  b0.left + (b0.width - w) * rnd.nextDouble(),
                  b0.top + (b0.height - h) * rnd.nextDouble(),
                  w,
                  h));
              gt.add(dupOf(o));
            }
          }
          if (rnd.nextDouble() < falsePosProb) {
            final w = 0.05 + 0.1 * rnd.nextDouble();
            boxes.add(Rect.fromLTWH(
                rnd.nextDouble() * (1 - w), rnd.nextDouble() * (1 - w), w, w));
            gt.add(-1);
          }
          // 탐지기 출력 순서는 의미 없으므로 섞음(순서에 기대는 버그 방지)
          final order = List.generate(boxes.length, (i) => i)..shuffle(rnd);
          return SimFrame(ms, [for (final i in order) boxes[i]],
              [for (final i in order) gt[i]]);
        }(),
    ];
  }
}

class SimFrame {
  SimFrame(this.timeMs, this.boxes, this.gt);
  final int timeMs;
  final List<Rect> boxes;

  /// boxes[i]의 정답 물체 인덱스, -1이면 오탐, [dupOf]면 그 물체의 일부를 한 번 더 잡은 박스
  final List<int> gt;
}

/// 물체 o의 일부를 중복으로 잡은 박스 표시(-2, -3, …)
int dupOf(int o) => -2 - o;

/// MOT 지표(단순화). 자율주행 추적 벤치마크(MOTChallenge·KITTI)의 핵심만.
class MotMetrics {
  int gtDetections = 0; // 추적기에 들어간 실제 물체 탐지 수
  int covered = 0; // 그 중 확정 ID가 붙은 수
  int idSwitches = 0; // 같은 물체의 ID가 바뀐 횟수(IDSW)
  final falseIdSet = <int>{}; // 오탐에 붙은 ID들
  final dupIdSet = <int>{}; // 같은 물체의 중복 박스에 붙은(그 물체 ID가 아닌) ID들
  final allIds = <int>{}; // 나온 확정 ID 전부(앱 PERF의 ids와 같은 것)
  double seconds = 0;

  /// 분당 새로 생긴 ID(실기기: 물체 1개 가만히 들고 약 65개/분)
  double get idsPerMin => seconds == 0 ? 0 : allIds.length / seconds * 60;
  final idsPerGt = <int, Set<int>>{};
  final _idCounts = <int, Map<int, int>>{};

  int get falseIds => falseIdSet.length;
  double get coverage => gtDetections == 0 ? 1 : covered / gtDetections;

  /// IDF1의 ID 재현율(IDR)처럼: 물체마다 가장 오래 붙은 ID 하나만 정답으로 인정.
  /// ID가 바뀌며 붙은 프레임은 "커버"는 돼도 여기선 빠집니다.
  double get idRecall => gtDetections == 0
      ? 1
      : _idCounts.values
              .map((c) => c.values.fold(0, math.max))
              .fold(0, (a, b) => a + b) /
          gtDetections;

  int get maxIdsPerObject =>
      idsPerGt.values.fold(0, (m, s) => math.max(m, s.length));

  @override
  String toString() =>
      'IDSW ${idSwitches.toString().padLeft(3)} | 물체당 ID 최대 ${maxIdsPerObject.toString().padLeft(2)} '
      '| 오탐 ID ${falseIds.toString().padLeft(2)} | 중복 ID ${dupIdSet.length.toString().padLeft(2)} '
      '| ID ${idsPerMin.toStringAsFixed(1).padLeft(5)}/분 | 커버율 ${(coverage * 100).toStringAsFixed(0).padLeft(3)}% '
      '| ID재현율 ${(idRecall * 100).toStringAsFixed(0).padLeft(3)}%';
}

class _Replay implements Detector {
  _Replay(this.frames);
  final List<SimFrame> frames;
  int _i = 0;

  @override
  Future<List<Detection>> detect(Frame frame) async => [
        for (final b in frames[_i++].boxes)
          Detection(trackingId: null, box: b, label: '', confidence: 0)
      ];

  @override
  Future<void> close() async {}
}

/// 가짜 자이로: 실제 화각이 앱의 가정보다 [fovError]만큼 넓은 폰을 흉내 내고(배율 오차),
/// 각속도에 잡음을 섞어 50Hz로 [GyroCameraMotion]에 넣습니다 → 실제 적분·보정 코드를 그대로 시험
class SimGyro {
  SimGyro(this.shift, {this.fovError = 0.25, int seed = 3})
      : _rnd = math.Random(seed);
  final Offset Function(double t) shift;
  final double fovError;
  final math.Random _rnd;
  final motion = GyroCameraMotion();
  int _t = 0;

  void advanceTo(int ms) {
    final kx = 1 / (GyroCameraMotion.defaultFovX * (1 + fovError));
    final ky = 1 / (GyroCameraMotion.defaultFovY * (1 + fovError));
    for (; _t + 20 <= ms; _t += 20) {
      final a = shift(_t / 1000), b = shift((_t + 20) / 1000);
      double noise() => 0.01 * (_rnd.nextDouble() * 2 - 1); // rad/s
      // 화면 +x 이동 ← ω_y > 0,  화면 +y 이동 ← ω_x > 0 (camera_motion.dart 주석 참고)
      motion.addSample(_t + 20, (b.dy - a.dy) / 0.02 / ky + noise(),
          (b.dx - a.dx) / 0.02 / kx + noise());
    }
  }
}

/// makeTracker(inner, motion)로 만든 추적기에 시나리오를 흘려 지표 계산.
/// gyro: true면 시나리오의 cameraShift로 만든 가짜 자이로를 motion으로 넘김
Future<MotMetrics> evaluate(Scenario s,
    Detector Function(Detector inner, CameraMotion? motion) makeTracker,
    {bool gyro = false}) async {
  final frames = s.simulate();
  final sim = gyro && s.cameraShift != null ? SimGyro(s.cameraShift!) : null;
  final tracker = makeTracker(_Replay(frames), sim?.motion);
  final m = MotMetrics();
  final lastId = <int, int>{};
  for (final f in frames) {
    sim?.advanceTo(f.timeMs);
    final out = await tracker.detect(Frame.file(
        timestampMs: f.timeMs, filePath: '', uprightSize: const Size(1, 1)));
    for (var i = 0; i < out.length; i++) {
      final g = f.gt[i], id = out[i].trackingId;
      if (id != null) m.allIds.add(id);
      if (g <= -2) {
        if (id != null && id != lastId[-2 - g]) m.dupIdSet.add(id);
        continue;
      }
      if (g < 0) {
        if (id != null) m.falseIdSet.add(id);
        continue;
      }
      m.gtDetections++;
      if (id == null) continue;
      m.covered++;
      (m.idsPerGt[g] ??= {}).add(id);
      final c = m._idCounts[g] ??= {};
      c[id] = (c[id] ?? 0) + 1;
      final prev = lastId[g];
      if (prev != null && prev != id) m.idSwitches++;
      lastId[g] = id;
    }
  }
  if (frames.length > 1) {
    m.seconds = (frames.last.timeMs - frames.first.timeMs) / 1000;
  }
  return m;
}

/// 균일 간격 프레임 시각
List<int> everyMs(int intervalMs, double seconds) =>
    [for (var t = 0; t <= seconds * 1000; t += intervalMs) t];

/// 불규칙 간격(처리 속도가 들쑥날쑥한 폰·에뮬레이터)
List<int> randomIntervals(int minMs, int maxMs, int count, {int seed = 7}) {
  final rnd = math.Random(seed);
  var t = 0;
  return [
    for (var i = 0; i < count; i++) t += minMs + rnd.nextInt(maxMs - minMs + 1)
  ];
}
