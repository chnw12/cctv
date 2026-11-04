import 'dart:math' as math;
import 'dart:ui';
import '../core/frame.dart';
import '../motion/camera_motion.dart';
import 'detector.dart';
import 'hungarian.dart';
import 'kalman.dart';

/// 아무 탐지기에나 씌우는 다중 물체 추적기(SORT/DeepSORT 방식 + 간이 카메라 움직임 보정).
///
/// 1. 예측: 트랙마다 칼만 필터(등속)로 "지금쯤 여기 있겠다"를 계산. 프레임 간격이
///    길거나(저사양·에뮬레이터 1FPS) 카메라가 움직여도 예측 위치로 비교합니다.
/// 2. 연결: 예측 박스와 탐지 박스의 IoU로 헝가리안 최적 할당. 확정 트랙을 먼저,
///    미확정 트랙은 남은 탐지로(DeepSORT의 matching cascade 단순화).
/// 3. 수명: minHits번 연속 잡혀야 ID 부여(미확정 중 한 번이라도 놓치면 폐기),
///    확정 트랙은 maxMissFrames 프레임 이상 **그리고** maxMissMs 이상 안 보여야 폐기.
///    → 시간만 보던 이전 방식은 처리 1FPS에서 매 프레임 잡혀도 만료돼 ID가 계속 새로 생겼음.
///    잃어버린 확정 트랙은 8초 동안 기억(ByteTrack·BoT-SORT의 lost track buffer): 카메라 움직임만큼 같이 옮기고
///    (maxMissFrames 넘게 못 찾으면) 속도는 줄여 제자리에 두었다가, 같은 자리에 다시 잡히면 원래 ID로 이음.
///    단 자이로 없이 화면이 흐르는 중(패닝)엔 그 자리가 부정확해 다른 물체가 지나가며 ID를 가져가므로(시나리오 ③) 잇지 않음 실기기(Z Flip7)에서 ML Kit이
///    어수선한 장면의 물체를 몇 초씩 빠뜨려 가만히 있어도 새 ID가 분당 ~65개 생기던 것(시나리오 ⑪⑫)
/// 3-1. 같은 물체의 일부를 한 번 더 잡은 박스: 이미 추적 중인 물체 박스 안에 대부분 들어가고 확실히 더 작으면
///      새 트랙을 안 만들고, 이미 트랙이 됐으면 나중 것을 지움(두 트랙이 번갈아 이어지며 ID가 뒤바뀌던 것, 시나리오 ⑪).
///      한 물체에 확정 트랙 둘이 거의 겹치고 같은 속도로 움직이면(서로 지나가는 두 물체는 속도가 다름) 먼저 생긴 ID만 남김
/// 4. 카메라 움직임 보정(BoT-SORT의 CMC 단순화): 폰을 돌리면 모든 물체가 같이 흐르므로,
///    이번 프레임 확정 트랙 속도의 중앙값을 새 트랙의 처음 속도로 줍니다. 패닝 중 화면에
///    새로 들어온 설비도 다음 프레임에 이어집니다. 그 추정이 틀릴 때(사람 한 명만 움직임)를
///    대비해 미확정 트랙은 직전 측정 위치와의 IoU도 같이 봅니다.
/// 5. 자이로 보정([motion] 있을 때): 자율주행의 ego-motion 보정처럼 폰 회전량만큼 모든 트랙의
///    예측 위치를 옮김. 확정 트랙이 없거나 패닝 시작 직후에도 동작하고, 정지 물체들의
///    예측 잔차로 화각 배율을 온라인 보정합니다.
///
/// ML Kit stream 모드의 내장 추적은 입력 FPS가 낮으면 계속 리셋되어 쓰지 않습니다.
/// 반환 목록은 inner가 준 탐지 순서 그대로입니다(같은 인덱스 = 같은 탐지).
class TrackingDetector implements Detector {
  TrackingDetector(
    this.inner, {
    this.minIou = 0.3,
    this.minHits = 3,
    this.minHitsMoving = 6,
    this.movingRate = 0.5,
    this.minConfirmMs = 400,
    this.tentativeMisses = 1,
    this.maxMissFrames = 3,
    this.maxMissMs = 8000,
    this.motion,
  });

  final Detector inner;

  /// 카메라(폰) 움직임 정보. null이면 4번(속도 중앙값)만으로 보정
  final CameraMotion? motion;

  /// 예측 박스와 이 이상 겹쳐야 같은 물체로 봄 (SORT 기본값 0.3)
  final double minIou;

  /// 이 횟수 연속으로 잡혀야 ID 부여 (DeepSORT n_init = 3)
  final int minHits;

  /// 폰이 빠르게 도는 중(자이로 [movingRate] 초과)에는 ID를 이만큼 연속으로 잡혀야 줌.
  /// 실기기 로그 재생: 빠르게 움직일 때 흐린 프레임에서 잠깐씩 나오는 박스가 3번(14FPS면 0.2초)을 넘겨
  /// 새 ID가 분당 ~50개 생김 → 움직임이 잦아들면 평소대로(3번). 자율주행에서 흔들림·번짐이 클 때 탐지를 덜 믿는 것과 같음
  final int minHitsMoving;
  final double movingRate;

  /// ID를 주기 전 최소 관찰 시간(ms). 처리 FPS가 높으면(실기기 14FPS) 3번이 0.2초뿐이라 움직일 때 흐린
  /// 프레임에서 잠깐 나온 박스에도 ID가 붙음. 대신 미확정 트랙이 [tentativeMisses]번까지 놓쳐도 살려 둬
  /// 진짜 물체가 깜빡임 때문에 확정 못 받는 일은 막음. 실기기 로그 재생: 새 ID 42.7→31.0/분,
  /// 합성 시나리오 12종 ID 재현율 평균 84.9→84.4%(최저 52% 그대로)
  final int minConfirmMs;
  final int tentativeMisses;

  /// 확정 트랙 폐기 조건: 놓친 프레임 수와 시간을 **둘 다** 넘어야 폐기.
  /// 빠를 땐 시간이, 느릴 땐 프레임 수가 가림(겹침) 동안 트랙을 지켜 줍니다.
  final int maxMissFrames;
  final int maxMissMs;

  /// 같은 물체의 일부로 보는 기준: 작은 박스 넓이의 [dupContained] 이상이 큰 박스 안이고,
  /// 큰 박스 넓이의 [dupMinArea]~[dupMaxArea] 배. 아주 작은 건 큰 설비 위의 다른 물체(계기판 등)일 수 있고,
  /// 크기가 비슷하면 서로 지나가는 다른 물체일 수 있어 둘 다 살림
  static const dupContained = 0.6, dupMinArea = 0.15, dupMaxArea = 0.7;

  /// 잃어버린(maxMissFrames 넘게 못 찾은) 트랙의 속도에 프레임마다 곱함
  static const lostVelocityDamping = 0.5;

  /// 손으로 돌리는 폰이 화면을 흘리는 최대 속도(화면/초)
  static const maxPanSpeed = 2.0;

  /// 자이로 없이 화면 흐름이 이보다 빠르면(화면/초) 잃어버린 트랙을 다시 잇지 않음
  static const reviveMaxSceneSpeed = 0.05;

  /// 같은 물체의 두 확정 트랙으로 보는 기준: 겹침(IoU)과 속도 차(화면/초)
  static const mergeIou = 0.6, mergeMaxSpeedDiff = 0.1;

  /// a가 b의 일부를 한 번 더 잡은 박스인가
  static bool isPartOf(Rect a, Rect b) {
    final aa = a.width * a.height, ab = b.width * b.height;
    if (aa <= 0 || ab <= 0 || aa < dupMinArea * ab || aa > dupMaxArea * ab) {
      return false;
    }
    final i = a.intersect(b);
    return i.width > 0 &&
        i.height > 0 &&
        i.width * i.height >= dupContained * aa;
  }

  final _tracks = <_Track>[];
  int _nextId = 1;
  int? _lastFrameMs;

  /// 자이로를 어디까지 적분했는지(센서 값이 늦게 와도 빠뜨리지 않게)
  int? _gyroCursor;

  /// 박스 정렬로 추정한 화면 흐름 속도(화면/초). 다음 프레임 정렬의 사전값(prior)
  Offset _globalVel = Offset.zero;

  /// 모든 트랙을 같은 양 s만큼 옮겼을 때 탐지와 맞는(IoU ≥ minIou) 트랙이 "이동 없음"보다
  /// 많아지면 s를 카메라 움직임으로 채택. 후보 s는 (탐지 중심 − 트랙 예측 중심) 쌍들.
  /// 배관·밸브처럼 같은 모양이 반복되면 여러 s가 비슷하게 맞으므로 prior에 가까운 것을 선호.
  /// "이동 없음"보다 더 맞아야만 채택하므로 정지 장면이나 물체 하나만 움직일 때는 0.
  /// maxShift: 자이로가 있으면 남은 오차만 다듬도록 작게(반복 패턴의 옆 칸으로 튀는 것 방지)
  /// dt: 직전 프레임과의 간격(초). 손으로 돌리는 폰은 화면을 초당 [maxPanSpeed]보다 빨리 못 흘리므로
  /// prior에서 그보다 먼 이동은 후보에서 뺌 — 바둑판처럼 줄지어 선 설비에서 한 줄이 사라지고 다른 줄이
  /// 나타난 순간 "한 줄 통째로 밀기"가 더 잘 맞아 보여 채택되면 ID가 줄 단위로 뒤바뀜(시나리오 ⑫, 14FPS에 한 프레임 0.4)
  Offset _register(List<Detection> dets, Offset prior,
      {double? maxShift, double dt = 0}) {
    // 확정 트랙이 2개 이상이면 그것만(한두 프레임짜리 오탐 트랙이 우연히 줄을 맞춰
    // 정지 장면 전체를 밀어 버리는 것 방지). 없을 때만(패닝 중 시작) 미확정까지 사용.
    // 오래 안 보이는(잃어버린) 트랙은 뺌 — 그 자리에 탐지가 없는 게 정상이라 "과반"을 깎음
    // 예측상 화면 밖으로 나가는 트랙은 못 찾는 게 정상이라 비교에서 뺌 — 안 빼면
    // 등간격 설비에서 "한 칸 옆으로 밀기"가 나간 트랙 몫만큼 더 맞아 보여 잘못 채택됨(시나리오 ③)
    const frame = Rect.fromLTRB(0, 0, 1, 1);
    bool onScreen(_Track t) {
      final b = t.kf.box, i = b.intersect(frame);
      return i.width > 0 &&
          i.height > 0 &&
          i.width * i.height >= 0.7 * b.width * b.height;
    }

    final confirmed = [
      for (final t in _tracks)
        if (t.id != null && t.misses <= 1) t
    ];
    final tracks =
        (confirmed.length >= 2 ? confirmed : _tracks).where(onScreen).toList();
    if (tracks.length < 2 || dets.length < 2) return Offset.zero;
    final widths = [for (final t in tracks) t.kf.box.width]..sort();
    final medianW = widths[widths.length ~/ 2];
    final scale = 4 * medianW;
    final limit = math.min(
        maxShift == null ? double.infinity : maxShift * medianW,
        dt > 0 ? maxPanSpeed * dt + 0.5 * medianW : double.infinity);

    (int, double) score(Offset s) {
      var n = 0;
      var sum = 0.0;
      for (final t in tracks) {
        final b = t.kf.box.shift(s);
        var best = 0.0;
        for (final d in dets) {
          final v = iou(b, d.box);
          if (v > best) best = v;
        }
        if (best >= minIou) {
          n++;
          sum += best;
        }
      }
      return (n, sum);
    }

    final (zeroN, _) = score(Offset.zero);
    final candidates = <Offset>[prior];
    for (final t in tracks) {
      for (final d in dets) {
        final r = d.box.width / t.kf.box.width;
        if (r < 0.5 || r > 2) continue; // 크기가 너무 다르면 같은 물체일 리 없음
        final s = d.box.center - t.kf.box.center;
        if (s.distance <= limit) candidates.add(s);
      }
    }
    var bestS = Offset.zero, bestN = zeroN;
    var bestJ = double.negativeInfinity;
    for (final s in candidates) {
      final (n, sum) = score(s);
      final j = n + 0.1 * sum - (s - prior).distance / scale;
      if (j > bestJ) {
        bestJ = j;
        bestS = s;
        bestN = n;
      }
    }
    // 카메라가 움직였다면 대부분이 같이 맞아야 함: 과반 + "이동 없음"보다 많이
    final majority = (tracks.length / 2).ceil();
    return bestN > zeroN && bestN >= 2 && bestN >= majority
        ? bestS
        : Offset.zero;
  }

  @override
  Future<List<Detection>> detect(Frame frame) async {
    final dets = await inner.detect(frame);
    final now = frame.timestampMs;

    // 1) 예측 (+ 카메라 회전만큼 이동)
    final last = _lastFrameMs;
    _lastFrameMs = now;
    var camShift = Offset.zero;
    final m = motion, cursor = _gyroCursor;
    if (m != null) {
      if (cursor == null) {
        _gyroCursor = now;
      } else {
        final (s, next) = m.shiftSince(cursor, now);
        camShift = s;
        _gyroCursor = next;
      }
    }
    for (final t in _tracks) {
      t.kf
        ..predict((now - t.stateMs) / 1000)
        ..shift(camShift);
      t
        ..stateMs = now
        ..lastBox = t.lastBox.shift(camShift) // 마지막으로 본 자리도 카메라 움직임만큼
        ..predCenter = t.kf.box.center;
    }

    // 1-1) 박스 정렬로 화면 전체 이동 추정(BoT-SORT CMC의 박스판).
    // 자이로가 있으면 자이로가 못 맞춘 나머지만 다듬고, 없으면(USB 캠 등) 이것이 주 보정
    final dt = last == null ? 0.0 : (now - last) / 1000;
    final reg = motion != null
        ? _register(dets, Offset.zero, maxShift: 0.5, dt: dt)
        : _register(dets, _globalVel * dt, dt: dt);
    if (reg != Offset.zero) {
      for (final t in _tracks) {
        t.kf.shift(reg);
        t.lastBox = t.lastBox.shift(reg);
      }
    }
    if (motion == null && dt > 0) {
      _globalVel =
          reg != Offset.zero ? (_globalVel + reg / dt) / 2 : _globalVel / 2;
    }

    // 2) 연결
    final detToTrack = List<_Track?>.filled(dets.length, null);
    void associate(List<_Track> tracks, {required bool alsoLastBox}) {
      final free = [
        for (var d = 0; d < dets.length; d++)
          if (detToTrack[d] == null) d
      ];
      if (tracks.isEmpty || free.isEmpty) return;
      double overlap(_Track t, Rect b) {
        final p = iou(t.kf.box, b);
        if (!alsoLastBox) return p;
        final l = iou(t.lastBox, b);
        return l > p ? l : p;
      }

      final cost = [
        for (final t in tracks)
          [for (final d in free) 1 - overlap(t, dets[d].box)]
      ];
      final a = hungarian(cost);
      for (var i = 0; i < tracks.length; i++) {
        if (a[i] < 0 || 1 - cost[i][a[i]] < minIou) continue;
        detToTrack[free[a[i]]] = tracks[i];
      }
    }

    // 확정 트랙도 마지막으로 본 자리와 비교: 몇 초 빠졌다 같은 자리에 다시 나온 물체를 원래 ID로.
    // 잃어버린 트랙은 그 자리를 믿을 수 있을 때만(자이로로 옮겼거나 화면이 거의 멈춤)
    final revive = motion != null || _globalVel.distance <= reviveMaxSceneSpeed;
    associate(
        _tracks
            .where((t) => t.id != null && (revive || t.misses <= maxMissFrames))
            .toList(),
        alsoLastBox: false);
    associate(_tracks.where((t) => t.id == null).toList(), alsoLastBox: true);

    // 3) 갱신
    final matched = <_Track>{};
    for (var d = 0; d < dets.length; d++) {
      final t = detToTrack[d];
      if (t == null) continue;
      t.kf.update(dets[d].box);
      t
        ..lastBox = dets[d].box
        ..hits += 1
        ..misses = 0
        ..lastSeenMs = now;
      matched.add(t);
    }

    // 4) 카메라 움직임 추정 → 새 트랙의 처음 속도, 자이로 배율 보정
    if (camShift != Offset.zero) {
      final residuals = [
        for (var d = 0; d < dets.length; d++)
          if (detToTrack[d]?.id != null)
            dets[d].box.center - detToTrack[d]!.predCenter
      ];
      if (residuals.length >= 2) {
        motion!.calibrate(camShift, _medianVelocity(residuals));
      }
    }
    final scene = _medianVelocity([
      for (final t in matched)
        if (t.id != null) t.kf.velocity
    ]);

    // 5) 못 찾은 트랙 정리
    for (final t in _tracks) {
      if (matched.contains(t)) continue;
      t.misses++;
      // 잠깐 놓친 건 그대로(패닝 중 속도는 진짜 카메라 움직임), 오래 놓치면 제자리에 세움
      if (t.misses > maxMissFrames) t.kf.dampVelocity(lostVelocityDamping);
    }
    _tracks.removeWhere((t) =>
        !matched.contains(t) &&
        (t.id == null && t.misses > tentativeMisses ||
            t.id != null &&
                t.misses > maxMissFrames &&
                now - t.lastSeenMs > maxMissMs));
    // 같은 물체에 트랙이 둘(일부를 따로 잡은 박스가 트랙이 됨) → 나중에 생긴 쪽을 지움
    _tracks.removeWhere((t) => _tracks.any((o) =>
        o != t &&
        o.id != null &&
        (t.id == null || t.id! > o.id!) &&
        (isPartOf(t.lastBox, o.lastBox) ||
            (iou(t.lastBox, o.lastBox) >= mergeIou &&
                (t.kf.velocity - o.kf.velocity).distance <
                    mergeMaxSpeedDiff))));

    // 6) 새 트랙 생성, ID 부여, 출력
    final out = <Detection>[];
    for (var d = 0; d < dets.length; d++) {
      final det = dets[d];
      var t = detToTrack[d];
      if (t == null) {
        if (_isPartOfTracked(det.box, dets, detToTrack)) {
          out.add(det); // 같은 물체를 한 번 더 잡은 박스: ID 없이 그대로
          continue;
        }
        t = _Track(BoxKalman(det.box, velocity: scene), det.box, now);
        _tracks.add(t);
      }
      final need =
          (motion?.angularSpeed ?? 0) > movingRate ? minHitsMoving : minHits;
      if (t.id == null && t.hits >= need && now - t.bornMs >= minConfirmMs) {
        t.id = _nextId++;
      }
      t.vote(det.label, det.confidence);
      final (label, conf) = t.bestLabel(det.confidence);
      out.add(Detection(
        trackingId: t.id,
        box: t.kf.box.intersect(const Rect.fromLTRB(0, 0, 1, 1)),
        label: label,
        confidence: conf,
      ));
    }
    return out;
  }

  /// 이번 프레임에 확정 트랙과 이어진 탐지 박스 안에 대부분 들어가는가(같은 물체의 일부)
  static bool _isPartOfTracked(
      Rect box, List<Detection> dets, List<_Track?> detToTrack) {
    for (var i = 0; i < dets.length; i++) {
      if (detToTrack[i]?.id != null && isPartOf(box, dets[i].box)) return true;
    }
    return false;
  }

  /// 성분별 중앙값(속도·잔차 모두에 사용)
  static Offset _medianVelocity(List<Offset> vs) {
    if (vs.isEmpty) return Offset.zero;
    double median(List<double> xs) {
      xs.sort();
      final m = xs.length ~/ 2;
      return xs.length.isOdd ? xs[m] : (xs[m - 1] + xs[m]) / 2;
    }

    return Offset(
        median([for (final v in vs) v.dx]), median([for (final v in vs) v.dy]));
  }

  static double iou(Rect a, Rect b) {
    final i = a.intersect(b);
    if (i.width <= 0 || i.height <= 0) return 0;
    final inter = i.width * i.height;
    return inter / (a.width * a.height + b.width * b.height - inter);
  }

  @override
  Future<void> close() => inner.close();
}

class _Track {
  _Track(this.kf, this.lastBox, int now)
      : stateMs = now,
        lastSeenMs = now,
        bornMs = now;

  final BoxKalman kf;
  Rect lastBox; // 마지막 측정 박스(예측이 빗나갔을 때 대비)
  Offset predCenter = Offset.zero; // 이번 프레임 예측 중심(자이로 보정 잔차용)
  int? id; // minHits 채우기 전에는 null
  int stateMs; // 칼만 상태의 시각
  int lastSeenMs;
  final int bornMs; // 처음 잡힌 시각
  int hits = 1;
  int misses = 0;

  /// 라벨은 프레임마다 깜빡이므로(ML Kit "Home good" ↔ 빈 값) 트랙 단위 다수결
  final _votes = <String, int>{};
  final _conf = <String, double>{};

  void vote(String label, double conf) {
    if (label.isEmpty) return;
    _votes[label] = (_votes[label] ?? 0) + 1;
    _conf[label] = conf;
  }

  (String, double) bestLabel(double fallbackConf) {
    if (_votes.isEmpty) return ('', fallbackConf);
    final best = _votes.entries.reduce((a, b) => b.value > a.value ? b : a).key;
    return (best, _conf[best]!);
  }
}
