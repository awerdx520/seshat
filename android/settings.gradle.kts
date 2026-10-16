// 插件解析仓库：优先走国内镜像（阿里云 gradle-plugin / google / public），
// 镜像未收录时回退官方 google()、mavenCentral()、gradlePluginPortal()。
pluginManagement {
    repositories {
        maven("https://maven.aliyun.com/repository/gradle-plugin")
        maven("https://maven.aliyun.com/repository/google")
        maven("https://maven.aliyun.com/repository/public")
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}
plugins {
    id("org.gradle.toolchains.foojay-resolver-convention") version "0.10.0"
}

// 依赖解析仓库：统一在根工程声明，子模块不再各自声明；同样镜像优先 + 官方兜底。
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        maven("https://maven.aliyun.com/repository/google")
        maven("https://maven.aliyun.com/repository/public")
        google()
        mavenCentral()
    }
}

rootProject.name = "seshat-android"

include(":app")
