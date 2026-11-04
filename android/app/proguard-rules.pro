# MediaPipe 손 인식(tasks-vision): 네이티브 코드가 자바 클래스·protobuf를 이름으로 찾음
-keep class com.google.mediapipe.** { *; }
-keep class com.google.protobuf.** { *; }
-dontwarn com.google.mediapipe.**
-dontwarn com.google.protobuf.**
# MediaPipe 로그(flogger)는 정적 초기화에서 백엔드를 이름으로 찾음 → 빠지면 ExceptionInInitializerError(에뮬레이터 재현)
-keep class com.google.common.flogger.** { *; }
-dontwarn com.google.common.flogger.**
# 설비 탐지기(ONNX Runtime): 네이티브 코드(JNI)가 ai.onnxruntime 클래스를 이름으로 찾음
-keep class ai.onnxruntime.** { *; }
-dontwarn ai.onnxruntime.**
