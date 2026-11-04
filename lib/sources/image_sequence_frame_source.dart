import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import '../core/jpeg.dart';
import '../core/frame.dart';
import 'frame_source.dart';

/// assets/test_frames/ 의 사진 + 폰의 앱 외부 저장소 test_frames/ 폴더 사진을 순서대로 반복 재생합니다.
/// (기계실 촬영본을 adb push로 넣으면 책상에서 탐지기를 비교:
///  테스트 이미지를 한 번 열어 폴더를 만든 뒤 adb push 사진.jpg /sdcard/Android/data/com.example.facility_camera/files/test_frames/)
class ImageSequenceFrameSource implements FrameSource {
  ImageSequenceFrameSource({this.fps = 5});
  final int fps;

  final _out = StreamController<Frame>.broadcast();
  final _current = ValueNotifier<String?>(null);
  final _paths = <String>[];
  final _sizes = <ui.Size>[];
  Timer? _timer;
  int _i = 0;
  final _aspect = ValueNotifier<double>(9 / 16);

  @override
  String get name => '테스트 이미지';
  @override
  ValueListenable<double> get aspectRatio => _aspect;
  @override
  Stream<Frame> get frames => _out.stream;

  @override
  Future<void> start() async {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final assets = manifest
        .listAssets()
        .where((a) =>
            a.startsWith('assets/test_frames/') &&
            RegExp(r'\.(jpg|jpeg|png)$', caseSensitive: false).hasMatch(a))
        .toList()
      ..sort();

    // ML Kit은 파일 경로 입력이 편해서 임시 폴더로 복사
    final dir = await getTemporaryDirectory();
    for (final a in assets) {
      final data = await rootBundle.load(a);
      final bytes = data.buffer.asUint8List();
      final f = File('${dir.path}/${a.split('/').last}');
      await f.writeAsBytes(bytes, flush: true);
      _paths.add(f.path);
      _sizes.add(await _decodeSize(bytes));
    }
    for (final f in await _pushedFrames()) {
      _paths.add(f.path);
      _sizes.add(await _decodeSize(await f.readAsBytes()));
    }
    if (_paths.isEmpty) {
      throw StateError('assets/test_frames/ 에 jpg/png 이미지를 넣어주세요.');
    }
    _aspect.value = _sizes.first.width / _sizes.first.height;
    _current.value = _paths.first;

    _timer = Timer.periodic(Duration(milliseconds: 1000 ~/ fps), (_) {
      final p = _paths[_i];
      final s = _sizes[_i];
      _aspect.value = s.width / s.height; // 사진마다 비율이 달라도 찌그러지지 않게
      _current.value = p;
      _out.add(Frame.file(
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        filePath: p,
        uprightSize: s,
      ));
      _i = (_i + 1) % _paths.length;
    });
  }

  Future<ui.Size> _decodeSize(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final fr = await codec.getNextFrame();
    final s = ui.Size(fr.image.width.toDouble(), fr.image.height.toDouble());
    fr.image.dispose();
    return s;
  }

  /// adb push로 넣은 사진(외부 저장소가 없는 기기·테스트 환경이면 없음).
  /// 폴더는 앱이 만들어 둠: adb가 만든 폴더는 앱 권한으로 못 읽음(에뮬레이터 Android 16에서 확인)
  static Future<List<File>> _pushedFrames() async {
    try {
      final ext = await getExternalStorageDirectory();
      if (ext == null) return const [];
      final d = Directory('${ext.path}/test_frames');
      if (!await d.exists()) {
        await d.create(recursive: true);
        return const [];
      }
      return (await d.list().toList())
          .whereType<File>()
          .where((f) => RegExp(r'\.(jpg|jpeg|png)$', caseSensitive: false)
              .hasMatch(f.path))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _out.close();
    _current.dispose();
    _aspect.dispose();
  }

  @override
  Future<Uint8List> snapshotJpeg() {
    final p = _current.value;
    if (p == null) throw StateError('이미지 준비 안 됨');
    return shrinkJpeg(p);
  }

  @override
  CameraControls? get controls => null;

  @override
  Widget buildPreview(BuildContext context) {
    return ValueListenableBuilder<String?>(
      valueListenable: _current,
      builder: (_, p, __) => p == null
          ? const SizedBox.shrink()
          : Image.file(File(p), fit: BoxFit.fill, gaplessPlayback: true),
    );
  }
}
