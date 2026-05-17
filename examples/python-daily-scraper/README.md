# Daily Python Scraper

Standalone consumer example for a daily Python job on ix.

It defines a uv project packaged with
[`ix.buildUvApplication`](../../lib/build-uv-application.nix), runs it as a
`systemd` oneshot service on a persistent daily timer, writes Parquet under
`/var/lib/daily-scraper/parquet`, and can sync the result to S3.

The Python stays ordinary Python. The ix-specific parts are
[`package.nix`](package.nix) and [`service.nix`](service.nix).

## Run

```sh
ix up
```

## Shape

- [`pyproject.toml`](pyproject.toml), [`uv.lock`](uv.lock), and [`src/`](src/)
  are the Python project.
- [`default.nix`](default.nix) defines one ix fleet node.
- [`service.nix`](service.nix) owns the service options, hardening, timer, and
  optional S3 sync.
- [`package.nix`](package.nix) packages the uv project as a store executable.
- [`flake.nix`](flake.nix) exposes the image package and the Python package.

## S3 Output

Set an S3 URI in the module config:

```nix
services.daily-scraper = {
  enable = true;
  s3 = {
    uri = "s3://andrew-scraper-output/github";
    awsEnvironmentFile = "/run/secrets/daily-scraper/aws.env";
  };
};
```

The AWS file is read at service start through `LoadCredential`, so the keys are
kept out of the Nix store. Its contents use systemd `EnvironmentFile` syntax:

```ini
AWS_ACCESS_KEY_ID=...
AWS_SECRET_ACCESS_KEY=...
AWS_REGION=us-east-1
```

## Swap In Your Script

Keep [`service.nix`](service.nix) and [`package.nix`](package.nix), then replace
the Python module and dependencies. The service already handles timer catch-up,
durable VM state, journald logs, and an S3 sync step that runs only after the
scraper succeeds.
