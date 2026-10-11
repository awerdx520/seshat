plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.serialization")
}

android {
    namespace = "com.notes.app"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.notes.app"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "0.1.0"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }
}

dependencies {
    // Android 基础库
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("com.google.android.material:material:1.12.0")

    // 阅读器 UI：ViewPager2 逐页翻页 + RecyclerView 适配器
    implementation("androidx.viewpager2:viewpager2:1.1.0")
    implementation("androidx.recyclerview:recyclerview:1.3.2")

    // 网络：OkHttp（WebDAV 自定义 method + REST）
    implementation("com.squareup.okhttp3:okhttp:4.12.0")

    // JSON：kotlinx.serialization
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")

    // 安全存储：同步令牌（auth_token）经 EncryptedSharedPreferences 加密保存
    implementation("androidx.security:security-crypto:1.1.0-alpha06")

    // 阅读：章节分页（左右滑动切换章节）
    implementation("androidx.viewpager2:viewpager2:1.1.0")
    // 阅读：WebViewAssetLoader —— 以 https 虚拟域提供 epub 内资源，规避 file:// 访问限制
    implementation("androidx.webkit:webkit:1.12.1")

    // 单元测试（JVM）
    testImplementation("junit:junit:4.13.2")
    testImplementation("com.squareup.okhttp3:mockwebserver:4.12.0")
}
