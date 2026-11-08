plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "build.agora.astation_mobile"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion
    lint { lintConfig = file("../lint.xml") }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "build.agora.astation.android"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        manifestPlaceholders["appAuthRedirectScheme"] = "build.agora.astation.android"
    }

    buildTypes {
        release {
            // Distribution signing is configured separately; never ship a debug-signed release.
        }
    }
}

val atemSdk = file("../../../build/atem-client/2b0c384e7213e5d4637cdba1f0a78ccbc53a2083/atem-client-android")
check(atemSdk.resolve("README.txt").isFile) {
    "Run python3 scripts/check-atem-client-android.py --install from the repository root."
}
android.sourceSets.getByName("main") {
    java.srcDir(atemSdk.resolve("kotlin"))
    jniLibs.srcDir(atemSdk.resolve("jniLibs"))
}
dependencies {
    implementation("net.java.dev.jna:jna:5.19.1@aar")
    implementation("net.openid:appauth:0.11.1")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20250517")
    // Keep Flutter's integration_test runtime aligned with the device-test runner.
    debugImplementation("androidx.test:core:1.6.1")
    debugImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test:core:1.6.1")
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
