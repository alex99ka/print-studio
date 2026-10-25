import java.util.Properties

// The release key lives outside the repo (~/.keystores, backed up to Drive);
// android/key.properties points at it and is gitignored. CI writes both from
// secrets. Every release must use the same key, or installed apps can't update.
val keyProperties = Properties().apply {
    rootProject.file("key.properties").takeIf { it.exists() }?.inputStream()?.use { load(it) }
}

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

/** MAJOR*1000000 + MINOR*1000 + PATCH: always rising with the version. */
fun versionCodeOf(name: String): Int {
    val p = name.split("+").first().split(".").map { it.toIntOrNull() ?: 0 } + listOf(0, 0, 0)
    return p[0] * 1_000_000 + p[1] * 1_000 + p[2]
}

android {
    namespace = "com.alex99ka.printstudio"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // flutter_local_notifications needs java.time on older Androids.
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.alex99ka.printstudio"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = versionCodeOf(flutter.versionName)
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            keyAlias = keyProperties.getProperty("keyAlias")
            keyPassword = keyProperties.getProperty("keyPassword")
            storePassword = keyProperties.getProperty("storePassword")
            storeFile = keyProperties.getProperty("storeFile")?.let { file(it) }
        }
    }

    buildTypes {
        release {
            // shortcut: falls back to the debug key without key.properties so a
            // fresh clone builds; such an APK can never update a released install.
            signingConfig = signingConfigs.getByName(
                if (keyProperties.isEmpty) "debug" else "release"
            )
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

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
}
