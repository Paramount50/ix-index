{
  errors,
  lib,
}:
let
  validDistributions = [
    "openjdk"
    "temurin"
    "corretto"
    "zulu"
  ];

  /**
    Per-distribution version → package mapping. Listed explicitly so an
    unknown version throws with the supported set for the chosen
    distribution rather than a confusing `attribute missing` deep in
    eval. The covered versions match the LTS lines nixpkgs ships
    headless variants for; bump the tables when a new LTS or platform
    target needs it.
  */
  jdksFor = pkgs: {
    openjdk = {
      "8" = pkgs.jdk8_headless;
      "11" = pkgs.jdk11_headless;
      "17" = pkgs.jdk17_headless;
      "21" = pkgs.jdk21_headless;
      "23" = pkgs.jdk23_headless;
      "24" = pkgs.jdk24_headless;
      "25" = pkgs.jdk25_headless;
    };
    temurin = {
      "8" = pkgs.temurin-bin-8;
      "11" = pkgs.temurin-bin-11;
      "17" = pkgs.temurin-bin-17;
      "21" = pkgs.temurin-bin-21;
      "23" = pkgs.temurin-bin-23;
      "24" = pkgs.temurin-bin-24;
      "25" = pkgs.temurin-bin-25;
    };
    corretto = {
      "11" = pkgs.corretto11;
      "17" = pkgs.corretto17;
      "21" = pkgs.corretto21;
      "25" = pkgs.corretto25;
    };
    zulu = {
      "8" = pkgs.zulu8;
      "11" = pkgs.zulu11;
      "17" = pkgs.zulu17;
      "21" = pkgs.zulu21;
      "23" = pkgs.zulu23;
      "24" = pkgs.zulu24;
      "25" = pkgs.zulu25;
    };
  };

  defaultDistribution = "openjdk";
  defaultVersion = "21";
in
{
  /**
    Return a JDK package for the requested version and distribution.

    Unknown distributions and unknown versions for a distribution throw
    with the supported set listed, so a typo (`"openjdkk"`, `"22"` when
    only `21` and `23` ship) is fixable from the message alone.

    OpenJDK uses the `_headless` variant by default so a server image
    that only needs the JDK does not pull X11 and CUPS into the closure.
    Pull a different distribution (Temurin, Corretto, Zulu) when an
    upstream needs a specific TCK-certified build.

    Arguments:
    - `pkgs`: nixpkgs instance the JDK comes from.
    - `version`: major version as a string (`"8" | "11" | "17" | "21" |
      "23" | "24" | "25"`). Defaults to `"21"`, the current
      long-term-support line.
    - `distribution`: one of `"openjdk" | "temurin" | "corretto" |
      "zulu"`. Defaults to `"openjdk"`.

    Example:
    ```nix
    { pkgs, ix, ... }:
    let
      jdk = ix.languages.java.jdk pkgs {
        version = "21";
        distribution = "temurin";
      };
    in {
      environment = {
        systemPackages = [ jdk ];
        variables.JAVA_HOME = jdk.home;
      };
    }
    ```
  */
  jdk =
    pkgs:
    {
      version ? defaultVersion,
      distribution ? defaultDistribution,
    }:
    let
      checkedDistribution = errors.assertEnum {
        name = "ix.languages.java.jdk.distribution";
        value = distribution;
        valid = validDistributions;
      };

      jdkTable = errors.requireAttr {
        context = "ix.languages.java.jdk: distribution table";
        attrset = jdksFor pkgs;
        key = checkedDistribution;
      };
    in
    errors.requireAttr {
      context = "ix.languages.java.jdk: unknown version for distribution '${checkedDistribution}'";
      attrset = jdkTable;
      key = version;
    };

  /**
    YourKit profiler integration for JVM services.

    See [`./yourkit.nix`](./yourkit.nix) for the option submodule plus the
    `flagsFor` / `portClaimFor` helpers that a service module pulls into
    its JVM args and firewall config when the option is enabled. Defaults
    are off; when enabled the agent loads at JVM startup so the first
    instruction is profiled (matches YourKit's startup-attach docs).
  */
  yourkit = import ./yourkit.nix { inherit errors lib; };
}
