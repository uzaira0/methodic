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

// Apply OWASP dependency check + ben-manes/versions audit to all subprojects
subprojects {
    apply(plugin = "org.owasp.dependencycheck")
    apply(plugin = "com.github.ben-manes.versions")

    configure<org.owasp.dependencycheck.gradle.extension.DependencyCheckExtension> {
        failBuildOnCVSS = 7.0f
        formats = listOf("HTML", "JSON", "SARIF")
        suppressionFile = "${rootProject.projectDir}/config/dependency-check-suppression.xml"

        withGroovyBuilder {
            "data" {
                setProperty("directory", "${rootProject.projectDir}/.dependency-check-data")
            }
            "analyzers" {
                setProperty("jarEnabled", true)
                setProperty("nodeEnabled", false)
                setProperty("nodeAuditEnabled", false)
                setProperty("assemblyEnabled", false)
            }
            "nvd" {
                setProperty("apiKey", System.getenv("NVD_API_KEY") ?: (findProperty("nvdApiKey") as String? ?: ""))
                // Inter-request delay (ms) for the NVD API. With a valid API key NVD allows
                // ~1 request / 0.6s; 1000ms stays safely under that. (3500ms was needlessly
                // conservative and made a cold full-feed pull take 4h+.)
                setProperty("delay", 1000)
            }
        }
    }
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
    description = "Collects all security reports into a single directory"
    from(subprojects.map { it.layout.buildDirectory.dir("reports") })
    into(rootProject.layout.buildDirectory.dir("reports/security"))
    include("**/dependency-check-report.*")
}
