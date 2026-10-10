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
            // Swift uses our UIKit/lifecycle bridges; dependency APIs stay inside Kotlin.
            transitiveExport = false
        }
    }

    sourceSets {
        commonMain.dependencies {
            api(compose.runtime)
            api(compose.foundation)
            api(compose.material3)
            api(compose.ui)
            api(libs.compose.material.icons.core)
            implementation("org.jetbrains.compose.material:material-icons-extended:1.7.3")
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
            // Render shared screens in JVM layout checks without adding an app target.
            implementation(compose.desktop.currentOs)
            implementation("org.jetbrains.kotlinx:kotlinx-coroutines-swing:${libs.versions.coroutines.get()}")
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

tasks.withType<Test>().configureEach {
    // UI rendering must never open a developer's accounts or download database.
    systemProperty("user.home", layout.buildDirectory.dir("ui-test-home").get().asFile.absolutePath)
    // Include Compose renders when CI restores a successful test task from the build cache.
    outputs.dir(layout.buildDirectory.dir("ui-layout"))
}
