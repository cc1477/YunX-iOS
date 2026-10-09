import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    alias(libs.plugins.kotlin.multiplatform)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
    alias(libs.plugins.compose.multiplatform)
    alias(libs.plugins.sqldelight)
}

kotlin {
    jvmToolchain(17)
    jvm("jvm") {
        compilerOptions {
            jvmTarget.set(JvmTarget.JVM_17)
        }
    }

    listOf(iosArm64(), iosSimulatorArm64()).forEach { target ->
        target.binaries.framework {
            baseName = "shared"
            isStatic = false
            // Kotlin/Native exports must also be declared as api in commonMain.
            // Keep transitive export off to avoid exposing the entire dependency graph.
            transitiveExport = false
            export(compose.runtime)
            export(compose.foundation)
            export(compose.material3)
            export(compose.ui)
            export(libs.compose.material.icons.core)
            export(libs.coroutines.core)
            export(libs.kotlinx.serialization.json)
            export(libs.ktor.client.core)
            export(libs.ktor.client.content.negotiation)
            export(libs.ktor.client.logging)
            export(libs.ktor.serialization.kotlinx.json)
        }
    }

    sourceSets {
        commonMain.dependencies {
            api(compose.runtime)
            api(compose.foundation)
            api(compose.material3)
            api(compose.ui)
            api(libs.compose.material.icons.core)
            api(libs.coroutines.core)
            api(libs.kotlinx.serialization.json)
            implementation(libs.kotlinx.datetime)
            api(libs.ktor.client.core)
            api(libs.ktor.client.content.negotiation)
            api(libs.ktor.client.logging)
            api(libs.ktor.serialization.kotlinx.json)
            implementation(libs.sqldelight.runtime)
            implementation(libs.lifecycle.viewmodel)
            implementation(libs.markdown.renderer.m3)
            implementation(libs.okio)
        }
        commonTest.dependencies {
            implementation(kotlin("test"))
        }
        iosMain.dependencies {
            implementation(libs.ktor.client.darwin)
            implementation(libs.sqldelight.native.driver)
        }
        jvmMain.dependencies {
            implementation(libs.ktor.client.cio)
            implementation(libs.sqldelight.sqlite.driver)
        }
        jvmTest.dependencies {
            implementation(kotlin("test-junit"))
            implementation(libs.junit)
        }
    }
}

sqldelight {
    databases {
        create("YunXDb") {
            packageName.set("com.yunx.app.data.db")
            srcDirs.setFrom("src/commonMain/sqldelight")
        }
    }
}
