plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "app.pult.tv"
    compileSdk = 34

    defaultConfig {
        applicationId = "app.pult.tv"
        minSdk = 26
        targetSdk = 33
        versionCode = 3
        versionName = "0.3.0"
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    buildTypes {
        getByName("release") {
            isMinifyEnabled = false
            // Testing builds only. For production use a persistent private signing key.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}
