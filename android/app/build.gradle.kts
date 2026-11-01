import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Keep signing credentials outside source control. CI can point this variable
// at its private properties file; developers can use ignored android/key.properties.
val releaseSigningFile = providers.environmentVariable("RELAY_SIGNING_PROPERTIES")
    .map { rootProject.file(it) }
    .getOrElse(rootProject.file("key.properties"))
val releaseSigningProperties = Properties().apply {
    if (releaseSigningFile.isFile) {
        releaseSigningFile.inputStream().use { load(it) }
    }
}
val releaseSigningFields = listOf("storeFile", "storePassword", "keyAlias", "keyPassword")
val releaseSigningReady = releaseSigningFields.all {
    !releaseSigningProperties.getProperty(it).isNullOrBlank()
}
val validateRelayReleaseSigning = tasks.register("validateRelayReleaseSigning") {
    doLast {
        if (!releaseSigningReady) {
            throw GradleException(
                "Release signing is required. Configure android/key.properties or " +
                    "RELAY_SIGNING_PROPERTIES. See docs/PLAY_RELEASE.md."
            )
        }
        val keystore = rootProject.file(releaseSigningProperties.getProperty("storeFile"))
        if (!keystore.isFile) {
            throw GradleException("The configured release keystore does not exist.")
        }
    }
}

android {
    namespace = "app.relay.relay"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "app.relay.relay"
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

    testOptions {
        unitTests {
            isIncludeAndroidResources = true
            all {
                it.jvmArgs(
                    "--add-opens=java.base/java.lang=ALL-UNNAMED",
                    "--add-opens=java.base/java.util=ALL-UNNAMED",
                    "--add-opens=java.base/java.io=ALL-UNNAMED",
                    "--add-opens=java.base/java.net=ALL-UNNAMED",
                    "--add-opens=java.base/java.security=ALL-UNNAMED",
                    "--add-opens=java.base/java.text=ALL-UNNAMED",
                    "--add-opens=java.base/jdk.internal.access=ALL-UNNAMED",
                    "--add-opens=java.desktop/java.awt.font=ALL-UNNAMED",
                    "--add-opens=jdk.compiler/com.sun.tools.javac.api=ALL-UNNAMED",
                )
            }
        }
    }

    signingConfigs {
        create("release") {
            if (releaseSigningReady) {
                storeFile = rootProject.file(releaseSigningProperties.getProperty("storeFile"))
                storePassword = releaseSigningProperties.getProperty("storePassword")
                keyAlias = releaseSigningProperties.getProperty("keyAlias")
                keyPassword = releaseSigningProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
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
    implementation("androidx.work:work-runtime-ktx:2.11.2")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.robolectric:robolectric:4.17")
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

// AGP's unit-test resource package also consumes Flutter's generated assets.
// The Flutter plugin wires app packaging but currently misses this AGP 9 task.
tasks.configureEach {
    val match = Regex("package(.+)UnitTestForUnitTest").matchEntire(name)
    if (match != null) {
        val assetTaskName = "copyFlutterAssets${match.groupValues[1]}"
        dependsOn(tasks.matching { it.name == assetTaskName })
    }
}

// Debug builds and unit tests work without a release key; release artifacts must
// never silently fall back to a debug key or an unsigned bundle.
tasks.configureEach {
    if (name in setOf(
            "validateSigningRelease", "signReleaseBundle", "packageRelease",
            "packageReleaseBundle", "assembleRelease", "bundleRelease",
        )) {
        dependsOn(validateRelayReleaseSigning)
    }
}
