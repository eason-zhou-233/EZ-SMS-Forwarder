plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.sms_forwarder"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    // 解决 JavaMail JAR 包中重复 META-INF 文件的冲突
    packaging {
        resources {
            excludes += setOf(
                "META-INF/NOTICE.md",
                "META-INF/LICENSE.md",
            )
        }
    }

    compileOptions {
        // 开启核心库脱糖
        isCoreLibraryDesugaringEnabled = true

        sourceCompatibility = JavaVersion.VERSION_21
        targetCompatibility = JavaVersion.VERSION_21
    }

    kotlinOptions {
        jvmTarget = "21"
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.sms_forwarder"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // 建议改为 34 或 35（即便你下载了 36，目前主流稳定开发建议用 34/35）
    // compileSdk = 34
    // buildToolsVersion = "34.0.0"

    buildTypes {
        release {
            // // 必须不低于 21 才能支持 telephony 插件
            // minSdk = flutter.minSdkVersion 
            // // 建议与 compileSdk 保持一致
            // targetSdkVersion = 34
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}

subprojects {
    afterEvaluate {
        val android = extensions.findByName("android") as? com.android.build.gradle.BaseExtension
        android?.apply {
            if (namespace == null) {
                namespace = "com.example.sms_forwarder.patch.${project.name}"
            }
        }
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    // Kotlin 协程（用于原生 Service 异步转发）
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3")
}
