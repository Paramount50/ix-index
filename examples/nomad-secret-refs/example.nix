{ index }:

let
  ix = index.lib;
  inherit (ix) pkgs;
  inherit (pkgs) lib;
  mkSecretSet =
    mountRoot:
    ix.secrets.normalize {
      provider = {
        type = "vaultwarden";
        client = "rbw";
        server = "https://vaultwarden.internal.example";
        inherit mountRoot;
        folder = "production";
      };

      values."daily-scraper/aws.env" = {
        key = "daily-scraper/aws-env";
        field = "notes";
        format = "env";
      };
    };
  secretSet = mkSecretSet "/run/ix-secrets";
  pureSecretSet = mkSecretSet "/build/ix-secrets";

  mkNomadJob =
    refs:
    ix.secrets.consumers.nomad.renderJob {
      name = "daily-scraper";
      image = "registry.ix.dev/indexable-inc/daily-scraper:latest";
      envSecretRefs = {
        "aws.env" = refs.values."daily-scraper/aws.env";
      };
    };
  nomadJob = mkNomadJob secretSet;
  pureNomadJob = mkNomadJob pureSecretSet;
  fakeRbw = pkgs.writeTextFile {
    name = "fake-rbw";
    executable = true;
    destination = "/bin/rbw";
    text = ''
      #!${lib.getExe pkgs.bash}
      set -euo pipefail
      if [ "$1" != "get" ]; then
        echo "unsupported rbw command: $*" >&2
        exit 64
      fi
      shift

      folder=""
      field=""
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --folder)
            folder="$2"
            shift 2
            ;;
          --field)
            field="$2"
            shift 2
            ;;
          --raw)
            shift
            ;;
          *)
            key="$1"
            shift
            ;;
        esac
      done

      if [ "''${folder:-}" != "production" ] || [ "''${field:-}" != "notes" ] || [ "''${key:-}" != "daily-scraper/aws-env" ]; then
        echo "unexpected rbw lookup folder=''${folder:-} field=''${field:-} key=''${key:-}" >&2
        exit 1
      fi

      printf '%s\n' 'AWS_ACCESS_KEY_ID=fake-access'
      printf '%s\n' 'AWS_SECRET_ACCESS_KEY=fake-secret'
      printf '%s\n' 'AWS_REGION=us-east-1'
    '';
  };

  fakeNomad = pkgs.writeTextFile {
    name = "fake-nomad";
    executable = true;
    destination = "/bin/nomad";
    text = ''
      #!${lib.getExe pkgs.bash}
      set -euo pipefail
      if [ "$1" != "job" ] || [ "$2" != "validate" ]; then
        echo "unsupported nomad command: $*" >&2
        exit 64
      fi
      grep -q 'source      = "/build/ix-secrets/daily-scraper/aws.env"' "$3"
      grep -q 'destination = "secrets/aws.env"' "$3"
      touch "$NOMAD_VALIDATE_SEEN"
    '';
  };
  pureValidateNomadJob = ix.secrets.consumers.nomad.runCommand {
    name = "daily-scraper-pure";
    secretSet = pureSecretSet;
    job = pureNomadJob;
    rbwProgram = lib.getExe fakeRbw;
    nomadProgram = lib.getExe fakeNomad;
  };
in
{
  inherit secretSet nomadJob;

  checkSecrets = ix.secrets.providers.vaultwarden.rbwCheckCommand secretSet.plan;
  materializeSecrets = ix.secrets.providers.vaultwarden.rbwMaterializeCommand secretSet.plan;

  validateNomadJob = ix.secrets.consumers.nomad.runCommand {
    name = "daily-scraper";
    inherit secretSet;
    job = nomadJob;
  };

  inherit pureValidateNomadJob;

  e2e = pkgs.runCommand "nomad-secret-refs-e2e" { nativeBuildInputs = [ pureValidateNomadJob ]; } ''
    export NOMAD_VALIDATE_SEEN="$PWD/nomad-validated"
    nomad-daily-scraper-pure-secrets-validate
    test -f "$NOMAD_VALIDATE_SEEN"
    grep -q '^AWS_ACCESS_KEY_ID=fake-access$' /build/ix-secrets/daily-scraper/aws.env
    grep -q '^AWS_SECRET_ACCESS_KEY=fake-secret$' /build/ix-secrets/daily-scraper/aws.env
    stat -c %a /build/ix-secrets/daily-scraper/aws.env | grep -qx 600
    mkdir -p "$out"
  '';

  kubernetesExternalSecret = ix.secrets.consumers.kubernetes.renderExternalSecret {
    name = "daily-scraper-aws";
    namespace = "batch";
    secretStoreRef = {
      name = "vaultwarden";
      kind = "ClusterSecretStore";
    };
    values = {
      AWS_ACCESS_KEY_ID = secretSet.values."daily-scraper/aws.env" // {
        key = "daily-scraper/aws-access-key-id";
      };
      AWS_SECRET_ACCESS_KEY = secretSet.values."daily-scraper/aws.env" // {
        key = "daily-scraper/aws-secret-access-key";
      };
    };
  };
}
