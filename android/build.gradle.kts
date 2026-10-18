group = "com.bilalahmed24.mic_recorder"
version = "0.1.0"

buildscript {
    repositories {
        google()
        mavenCentral()
    }
    dependencies {
        classpath("com.android.tools.build:gradle:9.1.0")
    }
}

rootProject.allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

plugins {
    id("com.android.library")
}

android {
    namespace = "com.bilalahmed24.mic_recorder"

    compileSdk = 36

    defaultConfig {
        minSdk = 24
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    // NotificationCompat + ContextCompat (receiver flags, runtime
    // permissions) — both used by the foreground-service, permission and
    // receiver code.
    implementation("androidx.core:core:1.15.0")
}
