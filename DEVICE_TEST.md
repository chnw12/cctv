# 실기기 테스트 안내

폰을 USB로 연결하고 명령 하나를 실행하면 **설치 → 화면 안내대로 조작(약 10분) → 로그 수집 → 자동 요약**까지 진행됩니다.
결과는 `build/device_logs/`에 남으니, 끝나면 "테스트 끝났어"라고만 알려 주시면 제가 읽고 분석·수정합니다.

## 1. 준비 (처음 한 번, 5분)
1. 폰 **설정 → 휴대전화 정보 → 소프트웨어 정보 → 빌드번호**를 7번 연속 탭 → "개발자 모드" 켜짐
   (삼성 기준. 다른 폰은 "빌드 번호"를 찾아 7번)
2. **설정 → 개발자 옵션 → USB 디버깅** 켜기 ("노드 트리 디버깅"은 다른 메뉴)
   - 최신 갤럭시: **설정 → 보안 및 개인정보 보호 → 자동 차단 기능**이 켜져 있으면 USB 디버깅을 켜도 PC에 안 잡힘 → 끄기
     (테스트 끝나면 다시 켜기 권장)
3. **데이터 전송되는** USB 케이블로 PC에 연결 (충전 전용 케이블이면 안 잡힘)
4. 폰에 "USB 디버깅을 허용하시겠습니까?" 뜨면 **"이 컴퓨터에서 항상 허용" 체크 → 허용**
5. 연결 확인 — 목록에 `emulator-…`가 아닌 줄이 `device`로 보이면 성공:
   ```bash
   /c/Users/leecw/AppData/Local/Android/sdk/platform-tools/adb.exe devices
   ```
   - 아무것도 안 보이면: 케이블 바꾸기, 폰 알림에서 USB 모드를 "파일 전송"으로, 삼성은 PC에 Samsung USB 드라이버 설치
   - `unauthorized`면: 폰 화면의 허용 팝업을 누르기

## 2. 실행
```bash
python tool/device_test.py run
```
- 맞는 APK(보통 `app-arm64-v8a-release.apk`, **실제 키 포함 → 다른 사람에게 주지 말 것**)를 설치하고 앱을 엽니다.
- 이전에 다른 방식으로 깐 앱과 충돌해 설치가 안 되면 `--reinstall` (폰의 점검 기록이 지워짐)
- 이미 깔린 그대로 하려면 `--no-install`, 중간에 그만두려면 `Ctrl+C` (거기까지 요약은 남음)

## 3. 화면 안내대로 할 일 (약 10분, 기계실·전기실이면 가장 좋음)
| 단계 | 할 일 | 자동으로 재는 것 | 끝나고 물어보는 것 |
|---|---|---|---|
| 1 준비 | 카메라 권한 허용 → 새 점검 → 카메라 화면 | 권한·카메라 열림 오류 | - |
| 2 가만히 (45초) | 설비를 향해 가만히 | 절전 비율, 자이로 영점 | - |
| 3 돌리기 (60초) | 천천히 좌우·상하로 | 처리 FPS·추론 시간, 화각 학습, 새 ID 수 | 박스 번호 유지됐나 |
| 4 AI 점검 ×3 | 볼륨 키 / AI 버튼 | 흔들림 대기·촬영·Gemini 응답 시간 | 설명·박스 위치가 맞나 |
| 5 위험 표시 고정 (30초) | AI 결과 띄운 채 크게 돌리기 | - | 박스가 따라갔나, 화살표 방향 |
| 6 어두운 곳 (40초) | 어두운 곳 20초 → 밝은 곳 | 어두움 판정·노출 보정·깜빡임 횟수 | 밝아졌나, 깜빡이지 않았나 |
| 7 조작 | 손전등·확대·탭 초점 | - | 각각 됐나 |
| 8 기록 | 기록 저장·사진만 기록·점검 종료 | 오류·강제 종료 | 기록이 남았나 |

질문에는 `y`(예) / `n`(아니오) / `s`(건너뜀)로 답하고, `n`이면 한 줄 메모를 남길 수 있습니다.

## 4. 배터리·발열 (선택, 30분)
```bash
python tool/device_test.py run --no-install --soak 30
```
- 위 단계를 다시 한 뒤, 앱 **설정 → 안 쓰면 카메라 멈춤 → "안 멈춤"** 으로 바꾸고 카메라 화면을 켠 채 세워 둡니다.
- USB에 꽂혀 있으면 충전 중이라 소모량을 못 재므로, 안내가 나오면 **케이블을 뽑고** 30분 뒤 다시 꽂으면 됩니다
  (그동안의 로그는 폰에 남아 있다가 다시 꽂을 때 가져옴).

## 4-1. 분석 로그(로그 재생, 추적기 튜닝용)
앱 **설정 → 개발자 → 분석 로그 기록**을 켜면 카메라 화면을 열 때마다 ML Kit 원본 탐지·자이로를 파일로 남깁니다.
1~2분(가만히 30초 → 천천히 좌우로 → 다시 가만히, 기계실이면 가장 좋음) 찍고 꺼낸 뒤 PC에서 추적기를 여러 설정으로 다시 돌립니다:
```bash
adb pull /sdcard/Android/data/com.example.facility_camera/files/analysis_logs build/analysis_logs
flutter test test/replay_log_test.dart --dart-define=REPLAY_LOG=build/analysis_logs/<파일>.jsonl -r expanded
```
지표: 새 ID/분(가만히 있을 때 0에 가까워야), 프레임당 탐지 박스 → 확정 물체 수, 새 ID가 나온 프레임 비율.

## 4-2. 탐지기 학습 데이터(설비 박스)
앱 **설정 → 개발자 → 탐지기 학습 데이터 모으기**를 켜고 평소처럼 AI 점검을 하면, 사진마다 Gemini가 짚은 설비(밸브·배관·분전반 등 10종) 박스가
YOLO 형식으로 쌓입니다. 꺼내서 검수:
```bash
adb pull /sdcard/Android/data/com.example.facility_camera/files/equipment_dataset build/equipment_dataset
python tool/dataset_review.py build/equipment_dataset
```
`build/equipment_dataset/review.html`을 열어 틀린 사진은 images/·labels/에서 같은 이름 두 파일을 지웁니다.

## 4-3. 설비 탐지기 비교(기계실에서 한 번에)
1. **설정 → 개발자**: 분석 로그 기록 · 탐지기 학습 데이터 모으기 · **녹화 버튼 보이기** 켜기
2. ML Kit(설비 탐지기 시험 **끔**)으로 카메라 화면 왼쪽 **● 녹화**를 누르고 1~2분: 가만히 20초 → 천천히 좌우로 → 다시 가만히.
   중간중간 AI 점검(데이터가 쌓임). 다시 누르면 멈추고 "녹화 저장: 시간 · 장 수 · MB" 알림
3. **설비 탐지기 시험 켬**(카메라가 다시 열림)으로 같은 동작 1분(녹화하면 시험판도 같은 장면으로 다시 볼 수 있음)
4. 시연 영상은 폰의 **화면 녹화**(빠른 설정 패널)로: 앱 화면(박스·번호·위험 표시)이 그대로 찍힘
5. PC에서:
```bash
adb pull /sdcard/Android/data/com.example.facility_camera/files/analysis_logs build/analysis_logs
adb pull /sdcard/Android/data/com.example.facility_camera/files/equipment_dataset build/equipment_dataset
adb pull /sdcard/Android/data/com.example.facility_camera/files/recordings build/recordings
flutter test test/replay_log_test.dart --dart-define=REPLAY_LOG=build/analysis_logs/<파일>.jsonl -r expanded
```
   `<yoloenv 파이썬> tool/equipment_model.py eval build/equipment_dataset` (YOLOE를 Gemini 박스와 비교),
   `... train build/equipment_dataset` (모은 데이터로 학습 → 앱 모델 교체, 다시 빌드)
6. 책상에서 사진으로 비교: 앱 **설정 → 카메라 테스트 화면 → 테스트 이미지**를 한 번 열면(폴더를 앱이 만듦) 사진을 넣을 수 있음.
   로그 `PERF equipment file=<사진> ms=… 이름:점수@l,t,r,b`로 사진마다 결과가 한 번씩 찍힘
```bash
adb push 사진.jpg /sdcard/Android/data/com.example.facility_camera/files/test_frames/
```

## 4-4. 시험용 녹화·재생(같은 장면으로 새 기능을 반복 시험)
앱 **설정 → 개발자 → 녹화 버튼 보이기**를 켜면 카메라 화면(점검·카메라 테스트) 왼쪽에 **● 녹화** 버튼이 생깁니다.
- 녹화되는 것: 카메라 원본 화면(JPEG, 1분에 약 60MB) + 자이로 + 줌 + 원본 탐지. 10분이면 자동으로 멈춤
- 위치: `/sdcard/Android/data/com.example.facility_camera/files/recordings/<시각>/`(`log.jsonl` + `frames/*.jpg`)
- **재생**: 카메라 테스트 화면 아래 **녹화 재생** → 녹화 고르기. 녹화가 진짜 카메라처럼 원래 간격대로 들어가서
  탐지·추적(녹화된 자이로로)·손 인식·AI 점검이 실제 카메라와 똑같이 돎. 끝나면 처음부터 반복
- **점검 화면 전체를 녹화로**: 설정 → 개발자 → **점검 화면을 녹화로 시험** → 녹화 고르기(되돌리려면 "카메라 쓰기").
  카메라 화면 왼쪽에 "▶ 녹화 재생" 표시
- 재생은 **녹화한 기기에서** 확인함. 다른 기기로 옮겨 재생하는 방법은 아직 확인 안 함(안드로이드 권한상 adb가 만든 폴더는
  앱이 못 읽음 — 에뮬레이터 Android 16에서 test_frames로 확인). PC 쪽 도구·재생 테스트는 어디서든 됨
- PC 도구(opencv 있는 파이썬, 예: tool/equipment_model.py용 가상환경):
```bash
python tool/recording_tool.py info   build/recordings/<녹화>
python tool/recording_tool.py video  build/recordings/<녹화> --boxes
python tool/recording_tool.py frames build/recordings/<녹화> --every 15
flutter test test/replay_log_test.dart --dart-define=REPLAY_LOG=build/recordings/<녹화>/log.jsonl -r expanded
```
  `video`: 똑바로 세운 MP4(`--boxes`면 원본 탐지 박스), `frames`: N장마다 사진(탐지기 평가·학습, 테스트 이미지용)

## 4-5. 앱 기록(오류·성능)
항상 켜져 있음. 쓰는 동안 나온 오류(+어디서)·성능 줄·지난번 앱이 꺼진 이유가 날짜별로 쌓입니다.
- 케이블 없이: 앱 **설정 → 개발자 → 앱 기록(오류·성능)** → 공유(카카오톡 나와의 채팅 등)
- 케이블로: `adb pull /sdcard/Android/data/com.example.facility_camera/files/app_logs build/app_logs`
- 한 줄 = `시각 I|E 내용`(E = 오류, 아래 들여쓴 줄은 스택)

## 5. 결과
- `build/device_logs/<시각>.log` — 원본 로그(앱 PERF·오류 줄 + 단계 표시 + 답변)
- `build/device_logs/<시각>_summary.txt` — 요약과 판정(`OK` / `확인`)

판정 기준(에뮬레이터 실측과 비교):
| 항목 | 좋음 | 에뮬레이터 |
|---|---|---|
| 처리 FPS(절전 아닐 때) | 카메라 15FPS의 60% 이상(9 이상) | 6~7 |
| 추론 시간 90% | 120ms 이하 | 80~160ms |
| 학습된 가로 화각 | 35~80° (보통 40~60°) | 43°(가짜 자이로) |
| 자이로 영점 | 0.015rad/s 미만 | 0 |
| 가만히 있을 때 절전 비율 | 50% 이상 | 100% |
| 촬영 / AI 응답 | 1초 / 5초 이하 | 0.5~0.8초 / 2~3초 |
| 밝기 전환 | 어두운 곳 한 번 다녀오면 2번 (6번 넘으면 깜빡임 의심) | - |
| 배터리(안 멈춤, 화면 켬) | 시간당 25% 이하 | - |
| 온도 / 메모리 | 42°C 이하 / 400MB 미만 | - / 150~290MB |

저장된 로그를 다시 요약하려면:
```bash
python tool/device_test.py summary build/device_logs/<시각>.log
```
