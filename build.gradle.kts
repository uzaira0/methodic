/*
 * Root build configuration for Methodic monorepo
 * Applies OWASP Dependency-Check plugin for security vulnerability scanning
 */

plugins {
    id("org.owasp.dependencycheck") version "12.2.2" apply false
}

// Apply OWASP dependency check to all subprojects
subprojects {
    apply(plugin = "org.owasp.dependencycheck")

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
                setProperty("apiKey", System.getenv("NVD_API_KEY") ?: "")
                setProperty("delay", 3500)
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
    from(subprojects.map { "${it.buildDir}/reports" })
    into("${rootProject.buildDir}/reports/security")
    include("**/dependency-check-report.*")
}
