/// 헝가리안(Kuhn–Munkres) 최소 비용 할당. SORT/ByteTrack의 연결 단계와 같은 방식.
/// cost[i][j] = 행 i를 열 j에 붙이는 비용. 결과[i] = 붙은 열(없으면 -1).
/// 행·열 수가 달라도 됩니다(남는 쪽은 -1).
List<int> hungarian(List<List<double>> cost) {
  final n = cost.length;
  if (n == 0) return const [];
  final m = cost.first.length;
  if (m == 0) return List.filled(n, -1);
  if (n > m) {
    // 알고리즘은 행 ≤ 열을 가정 → 전치해서 풀고 되돌림
    final t = [
      for (var j = 0; j < m; j++) [for (var i = 0; i < n; i++) cost[i][j]]
    ];
    final colToRow = hungarian(t);
    final out = List.filled(n, -1);
    for (var j = 0; j < m; j++) {
      if (colToRow[j] >= 0) out[colToRow[j]] = j;
    }
    return out;
  }

  // e-maxx 구현(1-기반 인덱스, 퍼텐셜 u·v)
  final u = List<double>.filled(n + 1, 0);
  final v = List<double>.filled(m + 1, 0);
  final p = List<int>.filled(m + 1, 0);
  final way = List<int>.filled(m + 1, 0);
  for (var i = 1; i <= n; i++) {
    p[0] = i;
    var j0 = 0;
    final minv = List<double>.filled(m + 1, double.infinity);
    final used = List<bool>.filled(m + 1, false);
    do {
      used[j0] = true;
      final i0 = p[j0];
      var delta = double.infinity;
      var j1 = 0;
      for (var j = 1; j <= m; j++) {
        if (used[j]) continue;
        final cur = cost[i0 - 1][j - 1] - u[i0] - v[j];
        if (cur < minv[j]) {
          minv[j] = cur;
          way[j] = j0;
        }
        if (minv[j] < delta) {
          delta = minv[j];
          j1 = j;
        }
      }
      for (var j = 0; j <= m; j++) {
        if (used[j]) {
          u[p[j]] += delta;
          v[j] -= delta;
        } else {
          minv[j] -= delta;
        }
      }
      j0 = j1;
    } while (p[j0] != 0);
    do {
      final j1 = way[j0];
      p[j0] = p[j1];
      j0 = j1;
    } while (j0 != 0);
  }
  final out = List.filled(n, -1);
  for (var j = 1; j <= m; j++) {
    if (p[j] != 0) out[p[j] - 1] = j - 1;
  }
  return out;
}
