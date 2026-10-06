import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Signing is read only from android/key.properties (gitignored).
// There is deliberately NO fallback to the Android debug keystore: a missing
// or incomplete key.properties fails the configuration phase with a clear message.
val keyPropsFile = rootProject.file("key.properties")
if (!keyPropsFile.exists()) {
    throw GradleException(
        "Signing config missing: create android/key.properties with storeFile, " +
            "storePassword, keyAlias and keyPassword. See README > Release signing."
    )
}
val keyProps = Properties().apply { keyPropsFile.inputStream().use { load(it) } }
val requiredSigningKeys = listOf("storeFile", "storePassword", "keyAlias", "keyPassword")
val missingSigningKeys = requiredSigningKeys.filter { keyProps.getProperty(it).isNullOrBlank() }
if (missingSigningKeys.isNotEmpty()) {
    throw GradleException(
        "android/key.properties is incomplete, missing: ${missingSigningKeys.joinToString()}"
    )
}
val signingStoreFile = rootProject.file(keyProps.getProperty("storeFile"))
if (!signingStoreFile.exists()) {
    throw GradleException("Keystore not found at ${signingStoreFile.path} (from storeFile in key.properties)")
}

android {
    namespace = "com.softdigi.softlocalpai"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.softdigi.softlocalpai"
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // Snapdragon 8 Gen 2 target only.
        ndk {
            abiFilters += "arm64-v8a"
        }

        externalNativeBuild {
            cmake {
                arguments += listOf("-DANDROID_STL=c++_static", "-DCMAKE_BUILD_TYPE=Release")
            }
        }
    }

    signingConfigs {
        create("real") {
            keyAlias = keyProps.getProperty("keyAlias")
            keyPassword = keyProps.getProperty("keyPassword")
            storeFile = signingStoreFile
            storePassword = keyProps.getProperty("storePassword")
        }
    }

    buildTypes {
        getByName("debug") {
            signingConfig = signingConfigs.getByName("real")
        }
        getByName("profile") {
            signingConfig = signingConfigs.getByName("real")
        }
        release {
            signingConfig = signingConfigs.getByName("real")
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }

    externalNativeBuild {
        cmake {
            path = file("../../native/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    packaging {
        jniLibs {
            useLegacyPackaging = false
        }
    }
}

flutter {
    source = "../.."
}
