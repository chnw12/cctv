import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter_image_compress/flutter_image_compress.dart';

/// AI 전송용으로 줄인 JPEG. 긴 변 ~1024px이면 위험요소 판단에 충분하고 업로드가 빠릅니다.
/// EXIF 회전도 픽셀에 반영해서 AI가 똑바로 선 사진을 받습니다.
Future<Uint8List> shrinkJpeg(String path) async {
  final out = await FlutterImageCompress.compressWithFile(
    path,
    minWidth: 1024,
    minHeight: 1024,
    quality: 80,
    autoCorrectionAngle: true,
    keepExif: false,
  );
  if (out == null) throw StateError('JPEG 변환 실패: $path');
  return out;
}

/// 디코딩 없이 헤더만 읽어 이미지 크기를 구합니다.
Future<Size> encodedImageSize(Uint8List bytes) async {
  final buf = await ImmutableBuffer.fromUint8List(bytes);
  final desc = await ImageDescriptor.encoded(buf);
  final s = Size(desc.width.toDouble(), desc.height.toDouble());
  desc.dispose();
  buf.dispose();
  return s;
}
