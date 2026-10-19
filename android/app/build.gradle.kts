import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.serialization")
}

// release 签名信息：读取 android/keystore.properties（该文件与 keystore 均不入 git）
// 缺失时不做签名配置，release 构建保持未签名（不影响 debug）
val keystorePropertiesFile = rootProject.file("keystore.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) {
        FileInputStream(keystorePropertiesFile).use { load(it) }
    }
}

android {
    namespace = "com.seshat.app"
    compileSdk = 35

    // release 签名配置（仅当 android/keystore.properties 存在时创建）
    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    defaultConfig {
        applicationId = "com.seshat.app"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "0.1.0"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    buildTypes {
        debug {
            // debug 变体：允许明文 http（仅用于本机 adb reverse 真机验证），
            // 实际放行的域由 src/debug/res/xml/network_security_config.xml 限定为本机回环
            manifestPlaceholders["usesCleartextTraffic"] = "true"
            resValue("bool", "allow_cleartext_http", "true")
        }
        release {
            isMinifyEnabled = false
            // release 恒为 https-only：禁止明文 http，校验器也不放宽
            manifestPlaceholders["usesCleartextTraffic"] = "false"
            resValue("bool", "allow_cleartext_http", "false")
            if (keystorePropertiesFile.exists()) {
                signingConfig = signingConfigs.getByName("release")
            }
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

    // Fragment：三区骨架的 Fragment 宿主（原由 appcompat 传递引入，此处显式固定版本）
    implementation("androidx.fragment:fragment:1.5.4")

    // 阅读器 UI：ViewPager2 逐页翻页 + RecyclerView 适配器
    implementation("androidx.viewpager2:viewpager2:1.1.0")
    implementation("androidx.recyclerview:recyclerview:1.3.2")

    // 网络：OkHttp（WebDAV 自定义 method + REST）
    implementation("com.squareup.okhttp3:okhttp:4.12.0")

    // JSON：kotlinx.serialization
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")

    // 安全存储：同步令牌（auth_token）经 EncryptedSharedPreferences 加密保存
    implementation("androidx.security:security-crypto:1.1.0-alpha06")

    // 阅读：WebViewAssetLoader —— 以 https 虚拟域提供 epub 内资源，规避 file:// 访问限制
    implementation("androidx.webkit:webkit:1.12.1")

    // PDF 目录（outline）解析：Android 版 Apache PDFBox（用户 2026-10-20 明确授权的唯一新增依赖）
    implementation("com.tom-roush:pdfbox-android:2.0.27.0")

    // 单元测试（JVM）
    testImplementation("junit:junit:4.13.2")
    testImplementation("com.squareup.okhttp3:mockwebserver:4.12.0")
}
