plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.facility_camera"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.facility_camera"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            // MediaPipe(손 인식)는 리플렉션·protobuf를 써서 코드 줄이기에서 빠지면 안 됨
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }

    // 손 인식 모델(.task)은 압축하지 않고 넣어야 MediaPipe가 바로 열 수 있음
    androidResources {
        noCompress += "task"
    }
}

dependencies {
    // 손 관절점 21개(AR: 손가락으로 위험 박스 누르기). 모델은 assets/hand_landmarker.task
    implementation("com.google.mediapipe:tasks-vision:0.10.35")
    // 설비 전용 탐지기(assets/equipment.onnx) 추론. Ultralytics의 TFLite 내보내기가 Windows에서 안 돼 ONNX로
    implementation("com.microsoft.onnxruntime:onnxruntime-android:1.31.1")
}

flutter {
    source = "../.."
}
