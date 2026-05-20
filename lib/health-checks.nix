/**
  Build a `health-checks` app that brings every example fleet up in
  parallel, verifies the declared `ix.healthChecks` via the existing
  `ix-fleet up` polling loop, and tears the VMs down on completion.

  Each example contributes a Nushell lifecycle script that sanity-checks
  for the `ix` binary, force-deletes any leftover VM with the same node
  name, invokes `fleet.up`, then force-deletes the VM again so the next
  run starts from scratch and an unrelated VM is never left running
  after a test.

  The fleets passed in are rebuilt with a `health-check-` `nodePrefix`
  applied by `exampleFleetsFor`, so the names this script force-deletes
  cannot collide with a production VM that happens to share the example's
  natural name (`nginx`, `factions`, `file-server`, ...).

  The lifecycle scripts are run in parallel by `dag-runner`, the
  repo-owned task runner. dag-runner reads a JSON spec describing the
  graph, fans out per-node tokio tasks, surfaces an inline indicatif
  spinner per task on a TTY (line output otherwise), captures stdout
  and stderr so failed nodes' logs are dumped at the end, and exits
  with the worst node exit code. Pass `--output json` to get an
  NDJSON event stream instead.
*/
{
  lib,
  pkgs,
  writeNushellApplication,
  dagRunner,
}:
{ exampleFleets }:
let
  jsonFormat = pkgs.formats.json { };

  mkLifecycle =
    name: fleet:
    let
      # Pin each node's OCI image as a build-time dep of the lifecycle script
      # so `nix run .#health-checks` realises every image before the runner
      # starts. Without this, `ix-fleet up` calls `nix-store --realise` on the
      # image .drv at runtime, which then triggers an x86_64-linux build chain
      # on whatever host launched the runner. Surfacing the realise step as a
      # normal Nix build fails fast at one well-known boundary instead of five
      # parallel runners independently rediscovering a broken remote builder.
      pinnedImages = lib.attrValues fleet.packages;
    in
    writeNushellApplication pkgs {
      name = "health-check-${name}";
      text = ''
        def main [] {
          let home = ($env.HOME? | default "")
          if $home != "" {
            $env.PATH = [$"($home)/.local/bin"] ++ $env.PATH
          }

          if (which ix | is-empty) {
            print -e $"[${name}] ix binary not found in PATH"
            print -e "  PATH segments:"
            for p in $env.PATH {
              print -e $"    ($p)"
            }
            print -e "  install the ix CLI into ~/.local/bin (or another PATH directory) before running health-checks"
            exit 1
          }

          let pinned_images = ${builtins.toJSON pinnedImages}
          let plan_data = (open ${fleet.plan})
          let nodes = $plan_data.order

          print $"[${name}] ($pinned_images | length) image\(s) pinned in store; removing any pre-existing VMs: ($nodes | str join ', ')"
          for node_name in $nodes {
            do --ignore-errors { ^ix rm --force $node_name } | ignore
          }

          print $"[${name}] booting and running health checks"
          let result = (^${lib.getExe fleet.up} | complete)
          if ($result.stdout | str length) > 0 {
            print $result.stdout
          }
          if ($result.stderr | str length) > 0 {
            print -e $result.stderr
          }

          print $"[${name}] tearing down"
          for node_name in $nodes {
            do --ignore-errors { ^ix rm --force $node_name } | ignore
          }

          exit $result.exit_code
        }
      '';
    };

  lifecycles = lib.mapAttrs mkLifecycle exampleFleets;

  spec = {
    nodes = lib.mapAttrs (_name: lifecycle: {
      command = [ (lib.getExe lifecycle) ];
    }) lifecycles;
  };

  specFile = jsonFormat.generate "health-checks-dag.json" spec;
in
writeNushellApplication pkgs {
  name = "health-checks";
  runtimeInputs = [ dagRunner ];
  text = ''
    def --wrapped main [...args] {
      exec ${lib.getExe dagRunner} ...$args ${specFile}
    }
  '';
}
