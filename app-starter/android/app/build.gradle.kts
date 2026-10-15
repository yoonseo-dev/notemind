plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "kr.ac.daelim.notemind"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "kr.ac.daelim.notemind"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

// 에뮬레이터의 127.0.0.1은 PC가 아니라 에뮬레이터 자신이라서, 디버그 빌드 때마다
// 연결된 모든 기기에 adb reverse를 걸어 PC의 Supabase·추론 서버로 이어 줍니다.
// 에뮬레이터를 다시 켜면 등록이 사라지므로 flutter run 할 때마다 다시 등록합니다.
val reversePorts = listOf(54321, 8000, 8001)
val adbPath = android.adbExecutable.absolutePath
val adbReverse = tasks.register("adbReverse") {
    doLast {
        fun adb(vararg args: String): String = try {
            val process = ProcessBuilder(adbPath, *args).redirectErrorStream(true).start()
            process.inputStream.bufferedReader().readText().also { process.waitFor() }
        } catch (e: Exception) {
            ""
        }
        val serials = adb("devices").lines().drop(1)
            .map { it.trim().split(Regex("\\s+")) }
            .filter { it.size >= 2 && it[1] == "device" }
            .map { it[0] }
        for (serial in serials) {
            for (port in reversePorts) adb("-s", serial, "reverse", "tcp:$port", "tcp:$port")
            logger.lifecycle("adb reverse $serial: ${reversePorts.joinToString()}")
        }
    }
}
tasks.matching { it.name == "assembleDebug" }.configureEach { dependsOn(adbReverse) }
