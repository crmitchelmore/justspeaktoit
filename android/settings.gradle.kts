// Dependency sources. By default Gradle resolves from Google Maven, Maven Central
// and the Gradle Plugin Portal. Set the Gradle property `jsti.mavenMirror` (or the
// JSTI_MAVEN_MIRROR environment variable) to resolve everything through a single
// proxy feed instead, as required on machines governed by a package-feed policy.
pluginManagement {
    val mirror = providers.gradleProperty("jsti.mavenMirror")
        .orElse(providers.environmentVariable("JSTI_MAVEN_MIRROR")).orNull
    repositories {
        if (mirror != null) {
            maven(mirror)
        } else {
            google {
                content {
                    includeGroupByRegex("com\\.android.*")
                    includeGroupByRegex("com\\.google.*")
                    includeGroupByRegex("androidx.*")
                }
            }
            mavenCentral()
            gradlePluginPortal()
        }
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    val mirror = providers.gradleProperty("jsti.mavenMirror")
        .orElse(providers.environmentVariable("JSTI_MAVEN_MIRROR")).orNull
    repositories {
        if (mirror != null) {
            maven(mirror)
        } else {
            google()
            mavenCentral()
        }
    }
}

rootProject.name = "JustSpeakToIt"
include(":app")
