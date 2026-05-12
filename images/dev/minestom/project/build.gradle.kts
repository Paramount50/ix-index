plugins {
    application
    java
}

group = "dev.ix"
version = "0.1.0"

dependencies {
    implementation("net.minestom:minestom:2026.04.13-1.21.11")
    implementation("ch.qos.logback:logback-classic:1.5.32")
}

java {
    toolchain {
        languageVersion = JavaLanguageVersion.of(25)
    }
}

application {
    mainClass = "dev.ix.minestom.Main"
}

dependencyLocking {
    lockAllConfigurations()
}

tasks.withType<JavaCompile>().configureEach {
    options.release = 25
}

tasks.jar {
    duplicatesStrategy = DuplicatesStrategy.EXCLUDE
    manifest {
        attributes["Main-Class"] = application.mainClass.get()
    }
    from({
        configurations.runtimeClasspath.get().map { dependency ->
            if (dependency.isDirectory) dependency else zipTree(dependency)
        }
    })
}
