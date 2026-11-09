import 'package:flutter/material.dart';

/// 안 써서 카메라를 멈췄을 때 화면 전체를 덮는 안내(탭하면 다시 시작)
class PausedOverlay extends StatelessWidget {
  const PausedOverlay({super.key, required this.onResume});
  final VoidCallback onResume;

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onResume,
        // 완전히 가림(뒤의 카메라 로딩 표시가 비쳐 "켜지는 중"으로 오해하지 않게)
        child: const ColoredBox(
          color: Colors.black,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.pause_circle_outline,
                    color: Colors.white70, size: 72),
                SizedBox(height: 12),
                Text('카메라 일시정지 · 배터리 절약 중',
                    style: TextStyle(color: Colors.white, fontSize: 18)),
                SizedBox(height: 6),
                Text('화면을 탭하거나 볼륨 키를 누르면 다시 시작',
                    style: TextStyle(color: Colors.white70)),
              ],
            ),
          ),
        ),
      );
}

/// 처음 점검할 때 한 번 보여 주는 숨은 조작법 안내
class CameraTipsCard extends StatelessWidget {
  const CameraTipsCard({super.key, required this.onClose});
  final VoidCallback onClose;

  static const _tips = [
    // 점검은 사람이 메인: 화면을 보느라 주변을 놓치지 않게 맨 먼저
    (Icons.front_hand, '멈춰 서서', '안전한 곳에 서서 비추기(걸으면서 화면 보지 않기)'),
    (Icons.volume_down, '볼륨 키', 'AI 점검(장갑 낀 채로도)'),
    (Icons.touch_app, '화면 탭', '그 위치에 초점·밝기'),
    (Icons.pinch, '두 손가락', '확대(또는 위쪽 1x 버튼)'),
    (Icons.add_a_photo, '사진만 기록', '인터넷 없을 때 → 나중에 AI 분석'),
    (Icons.flashlight_on, '손전등', '어두우면 위에 안내가 뜸'),
  ];

  @override
  Widget build(BuildContext context) => Card(
        margin: const EdgeInsets.all(24),
        color: Colors.black.withValues(alpha: 0.85),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                const Expanded(
                  child: Text('이렇게 쓰세요',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold)),
                ),
                IconButton(
                    onPressed: onClose,
                    icon: const Icon(Icons.close, color: Colors.white70)),
              ]),
              for (final (icon, title, desc) in _tips)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(children: [
                    Icon(icon, color: Colors.amberAccent),
                    const SizedBox(width: 10),
                    Text('$title  ',
                        style: const TextStyle(
                            color: Colors.white, fontWeight: FontWeight.bold)),
                    Expanded(
                        child: Text(desc,
                            style: const TextStyle(color: Colors.white70))),
                  ]),
                ),
              Align(
                alignment: Alignment.centerRight,
                child:
                    TextButton(onPressed: onClose, child: const Text('알겠어요')),
              ),
            ],
          ),
        ),
      );
}
