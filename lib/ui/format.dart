String _two(int v) => v.toString().padLeft(2, '0');

/// 10/31 14:05
String fmtDateTime(DateTime t) =>
    '${t.month}/${t.day} ${_two(t.hour)}:${_two(t.minute)}';

/// 2026-10-31 14:05
String fmtFull(DateTime t) =>
    '${t.year}-${_two(t.month)}-${_two(t.day)} ${_two(t.hour)}:${_two(t.minute)}';

/// 14:05:09
String fmtTime(DateTime t) =>
    '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';

/// 1시간 5분 / 12분 / 40초
String fmtDuration(Duration d) {
  if (d.inHours > 0) return '${d.inHours}시간 ${d.inMinutes % 60}분';
  if (d.inMinutes > 0) return '${d.inMinutes}분';
  return '${d.inSeconds}초';
}
