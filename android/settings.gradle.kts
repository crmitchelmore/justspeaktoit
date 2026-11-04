// Dependency sources. Package-feed policy forbids resolving directly from public registries
// (Google Maven, Maven Central, Gradle Plugin Portal), so every dependency and plugin resolves
// through exactly one approved feed, set with the Gradle property `jsti.mavenMirror` or the
// JSTI_MAVEN_MIRROR environment variable. That feed must proxy Maven Central and Google Maven.
// Without it the build stops rather than falling back to a public registry.
// pluginManagement is evaluated before the rest of this file, so it resolves the feed itself.
pluginManagement {
    val mirror = providers.gradleProperty("jsti.mavenMirror")
        .orElse(providers.environmentVariable("JSTI_MAVEN_MIRROR")).orNull
        ?.takeIf { it.isNotBlank() }
        ?: throw GradleException(
            "blocked: no approved Maven feed configured. Set -Pjsti.mavenMirror=<feed URL> or " +
                "JSTI_MAVEN_MIRROR to an approved feed that proxies Maven Central and Google Maven " +
                "(see android/README.md). Public registries are not used directly.",
        )
    repositories {
        maven(mirror)
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        maven(
            providers.gradleProperty("jsti.mavenMirror")
                .orElse(providers.environmentVariable("JSTI_MAVEN_MIRROR")).get(),
        )
    }
}

rootProject.name = "JustSpeakToIt"
include(":app")
