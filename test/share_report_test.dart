import 'dart:io';
import 'dart:ui' as ui;
import 'package:facility_camera/analysis/hazard.dart';
import 'package:facility_camera/data/share_report.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('공유용 사진: 원본 크기 그대로, 위험 박스 테두리가 빨갛게 그려짐', () async {
    final photo = File('assets/test_frames/scene_01.jpg'); // 1080x1440
    final report = HazardReport.fromJson({
      'summary': '',
      'hazards': [
        {
          'type': '분전반',
          'description': '',
          'severity': 'high',
          'action': '',
          'box_2d': [200, 200, 600, 600], // 0.2~0.6
        }
      ],
    }, 0, const ui.Size(1080, 1440));

    final png = await annotatedPhoto(photo, report);
    final img =
        (await (await ui.instantiateImageCodec(png)).getNextFrame()).image;
    expect(img.width, 1080);
    expect(img.height, 1440);

    final rgba = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    int px(int x, int y) => rgba.getUint32((y * img.width + x) * 4);
    // 왼쪽 테두리(x = 0.2*1080 = 216) 한가운데: 빨강(redAccent FF5252)
    final edge = px(216, 576);
    expect(edge >> 24 & 0xff, greaterThan(200), reason: 'R');
    expect(edge >> 16 & 0xff, lessThan(120), reason: 'G');
    // 박스 안쪽은 원본 그대로(빨강 아님)
    final inside = px(400, 600);
    expect(inside, isNot(edge));
  });
}
