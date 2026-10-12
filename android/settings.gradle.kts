// 插件解析仓库：AGP / Kotlin 插件从 google()、mavenCentral()、gradlePluginPortal() 获取。
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

// 依赖解析仓库：统一在根工程声明，子模块不再各自声明。
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "seshat-android"

include(":app")
