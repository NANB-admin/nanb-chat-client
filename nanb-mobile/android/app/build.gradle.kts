import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // Kotlin comes from Flutter's built-in Kotlin (no kotlin-android here —
    // applying KGP is deprecated and will fail future Flutter builds).
    // The Flutter Gradle Plugin must be applied after the Android Gradle plugin.
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.gms.google-services")
}

// Release signing. Secrets live in android/key.properties (gitignored) and the
// keystore in android/nanb-release.jks (gitignored). When key.properties is
// absent (other devs, CI), the release build falls back to debug signing so the
// build still succeeds — only distributable APKs need the real key.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseSigning = keystorePropertiesFile.exists()
if (hasReleaseSigning) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "us.nanb.chat"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        applicationId = "us.nanb.chat"
        // CoreCrypto AAR (com.wire:core-crypto-android:9.3.4) declares
        // minSdkVersion 26 — see Plan A's Maven-AAR pivot note.
        minSdk = 26
        // Pinned (not flutter.targetSdkVersion) so a Flutter SDK bump can't
        // silently move the target out from under Google Play's requirement.
        // Play currently mandates API 35 (Android 15) for new/updated apps; 36
        // clears that with a year of margin and matches Flutter 3.44's default.
        // Must stay <= compileSdk (inherited from Flutter: 36). Bump when Play
        // raises the floor.
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // Sign with the real release key when key.properties is present;
            // otherwise fall back to debug signing so non-distribution builds
            // (other devs, CI) still succeed.
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            // R8 already shrinks release builds here (nanb_crypto ships consumer
            // rules that rely on it). Make it explicit and add the app's own keep
            // rules so flutter_local_notifications' Gson TypeToken generic
            // signatures survive — otherwise cancel()/scheduling throw
            // `IllegalStateException: TypeToken must be created with a type
            // argument` at runtime (see app/proguard-rules.pro).
            isMinifyEnabled = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
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
    // Wire CoreCrypto moved to the local `nanb_crypto` plugin module
    // (../../nanb_crypto/android/build.gradle) along with the crypto
    // channel Kotlin — see NanbCryptoPlugin for why (FCM background
    // isolate needs the channel auto-registered on its own engine).
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")

    // Promotes flutter_secure_storage's transitive EncryptedSharedPreferences
    // onto our COMPILE classpath so MainActivity can read the app-lock pref from
    // the same encrypted store (to drive FLAG_SECURE when app-lock is on). The
    // plugin already pulls this exact version at runtime, so this only makes it
    // compile-visible — it does not change the resolved dependency graph.
    implementation("androidx.security:security-crypto:1.1.0-alpha06")
}
