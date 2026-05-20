{ ix, pkgs, ... }:
let
  L = ix.languages;

  # One JDK threaded through every JVM tool below so Java, Maven, Gradle,
  # Kotlin's stdlib runtime, Scala, sbt, mill, and Metals all share one
  # store path instead of pinning their own. Temurin 21 because it's the
  # current LTS and the Eclipse Adoptium TCK build most JVM upstreams
  # test against.
  jdk = L.java.jdk pkgs {
    version = "21";
    distribution = "temurin";
  };

  jvm = {
    inherit jdk;
    kotlin = L.kotlin.compiler pkgs { };
    scala = L.scala.compiler pkgs { inherit jdk; };
    maven = L.java.maven pkgs { inherit jdk; };
    gradle = L.java.gradle pkgs { inherit jdk; };
  };

  native = {
    # Stable rust here rather than the repo-default nightly: this VM is
    # for human iteration, not the repo's own clippy policy pipeline,
    # and `cargo` + `clippy` + `rustfmt` against stable removes the
    # nightly-feature foot-cannon.
    rust = L.rust.toolchain pkgs {
      channel = "stable";
      components = [
        "cargo"
        "clippy"
        "rust-src"
        "rust-std"
        "rustc"
        "rustfmt"
      ];
    };
    cpp = L.cpp.compiler pkgs { vendor = "gcc"; };
    cmake = L.cpp.cmake pkgs { };
    ninja = L.cpp.ninja pkgs { };
    zig = L.zig.toolchain pkgs { };
  };

  scripting = {
    python = L.python.interpreter pkgs { };
    go = L.go.toolchain pkgs { };
    node = L.javascript.node pkgs { version = "22"; };
    bun = L.javascript.bun pkgs { };
    deno = L.javascript.deno pkgs { };
    typescript = L.javascript.typescript pkgs { };
  };

  functional = {
    haskell = L.haskell.compiler pkgs { };
    cabal = L.haskell.cabal pkgs { };
    ocaml = L.ocaml.compiler pkgs { };
    dune = L.ocaml.dune pkgs { };
  };

  beam = {
    erlang = L.erlang.toolchain pkgs { };
    elixir = L.elixir.toolchain pkgs { };
    # Gleam is the BEAM-targeting statically-typed cousin whose compiler
    # itself is written in Rust; pairs with `erlang` above for the runtime.
    gleam = L.gleam.compiler pkgs { };
  };

  # Language servers stay together so an editor inside the VM finds the
  # whole set in one PATH lookup. `scala.languageServer` (Metals) needs
  # the same JDK the compiler was overridden against so loaded sources
  # parse against one runtime; the rest are JDK-independent.
  languageServers = [
    (L.cpp.languageServer pkgs { })
    (L.go.languageServer pkgs { })
    (L.haskell.languageServer pkgs { })
    (L.java.languageServer pkgs { })
    (L.javascript.languageServer pkgs { })
    (L.kotlin.languageServer pkgs { })
    (L.ocaml.languageServer pkgs { })
    (L.scala.languageServer pkgs { inherit jdk; })
    (L.zig.languageServer pkgs { })
  ];
in
{
  # The runtime JVM profile sets JAVA_HOME from the package it gets, so
  # passing the same `jdk` here makes `java -version`, `javac`, and
  # every JAR launched without an explicit `-Djava.home=...` line up
  # with the one Kotlin/Scala/Maven/Gradle were configured against.
  ix.profiles.jvm = {
    enable = true;
    package = jdk;
  };

  environment.systemPackages =
    (builtins.attrValues (builtins.removeAttrs jvm [ "jdk" ]))
    ++ builtins.attrValues native
    ++ builtins.attrValues scripting
    ++ builtins.attrValues functional
    ++ builtins.attrValues beam
    ++ languageServers;
}
