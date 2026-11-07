// Dependency sources (see "Android dependency sources" in android/README.md):
// - JSTI_MAVEN_MIRROR (or -Pjsti.mavenMirror) set: resolve only through that one feed.
// - Otherwise, on GitHub-hosted runners only: Google Maven and Maven Central.
// - Anywhere else (developer machines, self-hosted runners): stop, so a machine governed by a
//   package-feed policy never fetches from public registries by accident.
// A private feed takes credentials from jsti.mavenMirrorUser/jsti.mavenMirrorToken (for example in
// ~/.gradle/gradle.properties) or JSTI_MAVEN_MIRROR_USER/JSTI_MAVEN_MIRROR_TOKEN.
// Each block is evaluated in isolation by Gradle, so the selection is repeated in both.
pluginManagement {
    val mirror = providers.gradleProperty("jsti.mavenMirror")
        .orElse(providers.environmentVariable("JSTI_MAVEN_MIRROR")).orNull?.takeIf { it.isNotBlank() }
    val githubHosted = providers.environmentVariable("GITHUB_ACTIONS").orNull == "true" &&
        providers.environmentVariable("RUNNER_ENVIRONMENT").orNull == "github-hosted"
    repositories {
        when {
            mirror != null -> maven(mirror) {
                val token = providers.gradleProperty("jsti.mavenMirrorToken")
                    .orElse(providers.environmentVariable("JSTI_MAVEN_MIRROR_TOKEN")).orNull
                if (!token.isNullOrBlank()) {
                    credentials {
                        username = providers.gradleProperty("jsti.mavenMirrorUser")
                            .orElse(providers.environmentVariable("JSTI_MAVEN_MIRROR_USER")).getOrElse("jsti")
                        password = token
                    }
                }
            }
            githubHosted -> {
                google()
                mavenCentral()
            }
            else -> throw GradleException(
                "No Maven feed configured. Set JSTI_MAVEN_MIRROR (or -Pjsti.mavenMirror) to an approved feed " +
                    "that proxies Maven Central and Google Maven. Public registries are used only on " +
                    "GitHub-hosted runners. See android/README.md, \"Android dependency sources\".",
            )
        }
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    val mirror = providers.gradleProperty("jsti.mavenMirror")
        .orElse(providers.environmentVariable("JSTI_MAVEN_MIRROR")).orNull?.takeIf { it.isNotBlank() }
    repositories {
        // pluginManagement has already rejected unsupported environments.
        if (mirror != null) {
            maven(mirror) {
                val token = providers.gradleProperty("jsti.mavenMirrorToken")
                    .orElse(providers.environmentVariable("JSTI_MAVEN_MIRROR_TOKEN")).orNull
                if (!token.isNullOrBlank()) {
                    credentials {
                        username = providers.gradleProperty("jsti.mavenMirrorUser")
                            .orElse(providers.environmentVariable("JSTI_MAVEN_MIRROR_USER")).getOrElse("jsti")
                        password = token
                    }
                }
            }
        } else {
            google()
            mavenCentral()
        }
    }
}

rootProject.name = "JustSpeakToIt"
include(":app")
