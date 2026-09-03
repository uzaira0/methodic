/*
 * Root build configuration for Chronicle monorepo
 * Applies OWASP Dependency-Check plugin for security vulnerability scanning
 */

plugins {
    id("org.jetbrains.kotlin.jvm") apply false
    id("org.jetbrains.kotlin.plugin.spring") apply false
    id("com.github.spotbugs") apply false
    id("org.jetbrains.dokka") apply false
    id("com.github.jk1.dependency-license-report") apply false
    id("org.owasp.dependencycheck") version "12.2.2" apply false
    id("com.github.ben-manes.versions") version "0.52.0" apply false
}

val dependencyCheckAutoUpdate = providers.gradleProperty("dependencyCheckAutoUpdate")
    .map { it.toBoolean() }
    .orElse(true)
val dependencyCheckOffline = providers.gradleProperty("dependencyCheckOffline")
    .map { it.toBoolean() }
    .orElse(false)
val dependencyCheckNvdDelayMillis = providers.gradleProperty("dependencyCheckNvdDelayMillis")
    .map { it.toInt() }
    .orElse(1000)
val dependencyCheckNvdMaxRetryCount = providers.gradleProperty("dependencyCheckNvdMaxRetryCount")
    .map { it.toInt() }
    .orElse(10)
val dependencyCheckNvdResultsPerPage = providers.gradleProperty("dependencyCheckNvdResultsPerPage")
    .map { it.toInt() }
    .orElse(2000)
val dependencyCheckNvdValidForHours = providers.gradleProperty("dependencyCheckNvdValidForHours")
    .map { it.toInt() }
    .orElse(4)

// Apply OWASP dependency check + ben-manes/versions audit to all subprojects
subprojects {
    apply(plugin = "org.owasp.dependencycheck")
    apply(plugin = "com.github.ben-manes.versions")

    // stdlib-jdk7/jdk8 are empty relocation stubs since Kotlin 1.8; keep them on the
    // same version as kotlin_version in gradles/chronicle.gradle so transitive pulls
    // of old stubs can't downgrade the classpath.
    configurations.configureEach {
        resolutionStrategy.force(
            "org.jetbrains.kotlin:kotlin-stdlib-jdk7:2.3.21",
            "org.jetbrains.kotlin:kotlin-stdlib-jdk8:2.3.21",
        )
    }

    configure<org.owasp.dependencycheck.gradle.extension.DependencyCheckExtension> {
        autoUpdate = dependencyCheckAutoUpdate.get()
        val offline = dependencyCheckOffline.get()
        failBuildOnCVSS = 7.0f
        formats = listOf("HTML", "JSON", "SARIF")
        suppressionFile = "${rootProject.projectDir}/config/dependency-check-suppression.xml"
        scanConfigurations = listOf("runtimeClasspath")

        withGroovyBuilder {
            "data" {
                setProperty("directory", "${rootProject.projectDir}/.dependency-check-data")
            }
            "analyzers" {
                setProperty("jarEnabled", true)
                setProperty("nodeEnabled", false)
                setProperty("nodeAuditEnabled", false)
                setProperty("assemblyEnabled", false)
                "kev" {
                    setProperty("enabled", !offline)
                }
                "nodeAudit" {
                    setProperty("enabled", false)
                }
                "nodePackage" {
                    setProperty("enabled", false)
                }
                "ossIndex" {
                    setProperty("enabled", false)
                }
                "retirejs" {
                    setProperty("enabled", false)
                    setProperty("forceupdate", false)
                }
            }
            "hostedSuppressions" {
                setProperty("enabled", !offline)
                setProperty("forceupdate", false)
            }
            "nvd" {
                setProperty("apiKey", System.getenv("NVD_API_KEY") ?: (findProperty("nvdApiKey") as String? ?: ""))
                // Inter-request delay (ms) for the NVD API. With a valid API key NVD allows
                // ~1 request / 0.6s; 1000ms stays safely under that. (3500ms was needlessly
                // conservative and made a cold full-feed pull take 4h+.)
                setProperty("delay", dependencyCheckNvdDelayMillis.get())
                setProperty("maxRetryCount", dependencyCheckNvdMaxRetryCount.get())
                setProperty("resultsPerPage", dependencyCheckNvdResultsPerPage.get())
                setProperty("validForHours", dependencyCheckNvdValidForHours.get())
            }
        }
    }
}

tasks.register("dependencyCheckUpdateShared") {
    group = "verification"
    description = "Warms the shared OWASP Dependency-Check NVD database once for all subprojects"
    dependsOn(":chronicle-api:dependencyCheckUpdate")
}

// Aggregate dependency check task for all subprojects
tasks.register("dependencyCheckAll") {
    group = "verification"
    description = "Runs OWASP dependency-check analysis on all subprojects"
    dependsOn(subprojects.map { "${it.path}:dependencyCheckAnalyze" })
}

// Configure output directory for aggregate reports
tasks.register<Copy>("aggregateSecurityReports") {
    group = "verification"
    description = "Collects dependency-check reports produced by the explicit scan task"
    // Report aggregation must never trigger a second analysis. CI runs dependencyCheckAll
    // through scripts/local-ci.sh with the intended fresh/cache-only policy, then invokes
    // this task under `if: always()` solely to gather whatever evidence that run produced.
    subprojects.forEach { child ->
        from(child.layout.buildDirectory.dir("reports")) {
            into(child.name)
        }
    }
    into(rootProject.layout.buildDirectory.dir("reports/security"))
    include("**/dependency-check-report.*")
}
