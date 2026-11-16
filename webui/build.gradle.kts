import org.jetbrains.kotlin.gradle.ExperimentalWasmDsl

plugins {
    alias(libs.plugins.kotlinMultiplatform)
    alias(libs.plugins.composeCompiler)
    alias(libs.plugins.composeMultiplatform)
}

kotlin {
    jvmToolchain(21)

    // Host target for the unit tests of the status parser and state mapping.
    // Nothing from this target is shipped.
    jvm()

    @OptIn(ExperimentalWasmDsl::class)
    wasmJs {
        outputModuleName = "console"
        browser {
            commonWebpackConfig {
                outputFileName = "console.js"
            }
        }
        binaries.executable()
    }

    sourceSets {
        commonMain.dependencies {
            // The Compose compiler plugin is applied to every target and
            // requires its runtime on the classpath even for plain Kotlin.
            implementation(libs.compose.runtime)
            implementation(libs.kotlinx.coroutines.core)
        }
        commonTest.dependencies {
            implementation(kotlin("test"))
            implementation(libs.kotlinx.coroutines.test)
        }
        wasmJsMain.dependencies {
            implementation(libs.compose.foundation)
            implementation(libs.compose.ui)
            implementation(libs.miuix.ui)
            implementation(libs.miuix.preference)
            implementation(libs.miuix.icons)
        }
    }
}

// CMP 1.12's checkComposeUiTestConfigurationFor* false-positives on any Skiko
// dependency (CMP-4906); this project runs no Compose UI browser tests.
tasks.matching { it.name.startsWith("checkComposeUiTestConfigurationFor") }.configureEach {
    enabled = false
}
