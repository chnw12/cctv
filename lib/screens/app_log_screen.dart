import 'dart:io';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import '../core/app_log.dart';

/// 앱 기록 보기(설정 → 개발자): 날짜별 기록 파일의 마지막 줄들, 오류만 보기, 공유(케이블 없이 PC로 보낼 때)
class AppLogScreen extends StatefulWidget {
  const AppLogScreen({super.key});

  @override
  State<AppLogScreen> createState() => _AppLogScreenState();
}

class _AppLogScreenState extends State<AppLogScreen> {
  List<File> _files = const [];
  File? _file;
  List<String> _lines = const [];
  bool _errorsOnly = false;

  /// 화면에 보여 줄 최대 줄 수(파일은 그대로, 공유하면 전체)
  static const _maxLines = 800;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load([File? pick]) async {
    AppLog.flush();
    final files = await AppLog.files();
    final f = pick ?? (files.isEmpty ? null : files.first);
    final lines = f == null ? const <String>[] : await f.readAsLines();
    if (!mounted) return;
    setState(() {
      _files = files;
      _file = f;
      _lines = lines;
    });
  }

  /// 오류 줄과 그 아래 스택 줄(시각으로 시작하지 않는 줄)을 같이 묶음
  List<(String, bool)> get _shown {
    final out = <(String, bool)>[];
    var inError = false;
    for (final l in _lines) {
      final head = RegExp(r'^\d\d:\d\d:\d\d\.\d{3} ([IE]) ').firstMatch(l);
      if (head != null) inError = head[1] == 'E';
      if (!_errorsOnly || inError) out.add((l, inError));
    }
    return out.length > _maxLines ? out.sublist(out.length - _maxLines) : out;
  }

  int get _errorCount => _lines
      .where((l) => RegExp(r'^\d\d:\d\d:\d\d\.\d{3} E ').hasMatch(l))
      .length;

  Future<void> _share() async {
    final f = _file;
    if (f == null) return;
    AppLog.flush();
    await SharePlus.instance.share(ShareParams(
      subject: '[시설 안전카메라] 앱 기록 ${f.uri.pathSegments.last}',
      files: [XFile(f.path, mimeType: 'text/plain')],
    ));
  }

  @override
  Widget build(BuildContext context) {
    final shown = _shown;
    return Scaffold(
      appBar: AppBar(
        title: const Text('앱 기록'),
        actions: [
          IconButton(
              tooltip: '새로 읽기',
              onPressed: () => _load(_file),
              icon: const Icon(Icons.refresh)),
          IconButton(
              tooltip: '공유',
              onPressed: _file == null ? null : _share,
              icon: const Icon(Icons.share)),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(
              children: [
                if (_files.isNotEmpty)
                  DropdownButton<File>(
                    value: _file,
                    items: [
                      for (final f in _files)
                        DropdownMenuItem(
                            value: f,
                            child: Text(f.uri.pathSegments.last
                                .replaceAll('.log', ''))),
                    ],
                    onChanged: (f) => _load(f),
                  ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text('${_lines.length}줄 · 오류 $_errorCount건',
                      style: TextStyle(
                          color: _errorCount > 0 ? Colors.redAccent : null)),
                ),
                FilterChip(
                  label: const Text('오류만'),
                  selected: _errorsOnly,
                  onSelected: (v) => setState(() => _errorsOnly = v),
                ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(
                '오류·성능 줄이 날짜별로 쌓임(14일 보관). 공유 버튼으로 PC에 보내거나, '
                '케이블이 있으면 adb pull …/files/app_logs',
                style: TextStyle(fontSize: 12, color: Colors.white60)),
          ),
          const Divider(height: 1),
          Expanded(
            child: shown.isEmpty
                ? const Center(child: Text('기록이 없습니다'))
                : ListView.builder(
                    // 최근 줄이 아래 → 열면 맨 아래부터
                    reverse: true,
                    itemCount: shown.length,
                    itemBuilder: (_, i) {
                      final (line, err) = shown[shown.length - 1 - i];
                      return Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 1),
                        child: Text(line,
                            style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 11,
                                color: err ? Colors.redAccent : null)),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
