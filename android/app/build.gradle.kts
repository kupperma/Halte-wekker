import java.util.Properties

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
}

// Release signing: a keystore given by environment (CI: from the repository secrets) or by a local
// `signing.properties` (never committed). Without one, the release is signed with the debug key: a test build.
val signing = Properties().apply {
    val f = rootProject.file("signing.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}
fun signingValue(env: String, prop: String): String? =
    System.getenv(env)?.takeIf { it.isNotBlank() } ?: signing.getProperty(prop)?.takeIf { it.isNotBlank() }
val keystorePath = signingValue("HW_KEYSTORE_FILE", "storeFile")
val hasReleaseKey = keystorePath != null && file(keystorePath).exists()

// The school list is the iOS app's own file (ios/App/Schools.json), copied in at build time: one list for both apps.
val copySchools by tasks.registering(Copy::class) {
    from(rootProject.file("../ios/App/Schools.json"))
    // (A3) NS's stations, for the coach picker and a friend's start area: the iOS app's own list too
    from(rootProject.file("../ios/App/NSStations.json"))
    into(layout.buildDirectory.dir("generated/schools"))
}

android {
    namespace = "nl.haltewekker"
    compileSdk = 35

    defaultConfig {
        applicationId = "nl.haltewekker.android"
        minSdk = 26
        targetSdk = 35
        versionCode = 19
        versionName = "0.10.6"
        // phones: ARM only (the map's native library is 11 MB per ABI; x86 is emulators and a few Chromebooks)
        ndk { abiFilters += listOf("arm64-v8a", "armeabi-v7a") }
    }

    signingConfigs {
        if (hasReleaseKey) {
            create("release") {
                storeFile = file(keystorePath!!)
                storePassword = signingValue("HW_KEYSTORE_PASSWORD", "storePassword")
                keyAlias = signingValue("HW_KEY_ALIAS", "keyAlias")
                keyPassword = signingValue("HW_KEY_PASSWORD", "keyPassword")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            signingConfig = if (hasReleaseKey) signingConfigs.getByName("release") else signingConfigs.getByName("debug")
        }
        debug {
            applicationIdSuffix = ".debug"
        }
    }

    sourceSets["main"].assets.srcDir(layout.buildDirectory.dir("generated/schools"))

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
        freeCompilerArgs += listOf(
            "-opt-in=androidx.compose.foundation.layout.ExperimentalLayoutApi",
            "-opt-in=androidx.compose.material3.ExperimentalMaterial3Api",
        )
    }
    buildFeatures {
        compose = true
        buildConfig = true
    }
    packaging {
        resources.excludes += "/META-INF/{AL2.0,LGPL2.1}"
        jniLibs.useLegacyPackaging = true      // compressed in the APK: a smaller download
    }
    testOptions {
        unitTests.isReturnDefaultValues = true
    }
}

tasks.named("preBuild") { dependsOn(copySchools) }

dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.lifecycle.service)
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.ui.tooling.preview)
    implementation(libs.compose.material3)
    implementation(libs.compose.material.icons)
    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.kotlinx.serialization.json)
    implementation(libs.okhttp)
    implementation(libs.maplibre)
    implementation(libs.androidx.work)
    // A3 Friends: Ed25519, X25519, HKDF and ChaCha20-Poly1305 (pure Java: the platform has them only from API 31/33)
    implementation(libs.bouncycastle)
    // the friend code's QR: drawn and read with ZXing (no Play services), the camera through CameraX
    implementation(libs.zxing.core)
    implementation(libs.camerax.camera2)
    implementation(libs.camerax.lifecycle)
    implementation(libs.camerax.view)

    testImplementation(libs.junit)
}
