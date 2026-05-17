# Daily Python Scraper

Downstream-style ix example for a Python job that runs once per day, fetches
data over HTTP, writes Parquet under `/var/lib/daily-scraper/parquet`, and can
sync the result to S3.

For Andrew's scraper shape, the ix-specific work is small:

- package the script as a uv app: [`pyproject.toml`](pyproject.toml),
  [`uv.lock`](uv.lock), and [`src/`](src/)
- wrap the app with [`ix.buildUvApplication`](../../lib/build-uv-application.nix)
  in [`package.nix`](package.nix)
- run it from a `systemd` oneshot service and a persistent daily timer in
  [`service.nix`](service.nix)
- choose the output home: VM state for local retention, or an S3 URI with
  short-lived AWS credentials

The reusable NixOS module is 163 lines. The Python stays ordinary Python.

## Layout

- [`default.nix`](default.nix) defines one ix fleet node.
- [`service.nix`](service.nix) owns the service options, hardening, timer, and
  optional S3 sync.
- [`package.nix`](package.nix) builds the uv project into a store executable.
- [`src/daily_scraper/__init__.py`](src/daily_scraper/__init__.py) fetches one
  GitHub repository record and writes a date-stamped Parquet file.
- [`flake.nix`](flake.nix) exposes fleet commands plus the Python package.

## Use

From this directory:

```bash
nix run .#plan
nix run .#up
nix run .#switch
```

Build the Python command alone:

```bash
nix build .#daily-scraper
```

After the VM is running, inspect the schedule and the last run:

```bash
ix shell scraper -- /run/current-system/sw/bin/systemctl list-timers daily-scraper.timer
ix shell scraper -- /run/current-system/sw/bin/journalctl --no-pager -u daily-scraper.service -n 80
```

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
the Python module and dependencies. The service already handles network
ordering, durable state, timer catch-up after downtime, logs through journald,
and an upload step that only runs after the scraper exits successfully.
