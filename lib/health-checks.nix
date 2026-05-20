/**
  Build a `health-checks` app that brings every example fleet up in
  parallel, verifies the declared `ix.healthChecks` via the existing
  `ix-fleet up` polling loop, and tears the VMs down on completion.

  Each example contributes a small Nushell lifecycle script that
  force-deletes any leftover VM with the same node name, invokes
  `fleet.up` (which boots and polls health checks), then force-deletes
  the VM again so the next run starts from scratch and an unrelated VM
  is never left running after a test.

  The lifecycle scripts are run in parallel through `process-compose`.
  A sentinel `_done` process depends on every example with
  `process_completed` and triggers `exit_on_end`, so the supervisor
  shuts down cleanly even when one or more examples fail. The exit
  code from `process-compose up` is non-zero if any lifecycle exited
  non-zero, so `nix run .#health-checks` propagates the test result.
*/
{
  lib,
  pkgs,
  writeNushellApplication,
}:
{ exampleFleets }:
let
  yamlFormat = pkgs.formats.yaml { };

  mkLifecycle =
    name: fleet:
    writeNushellApplication pkgs {
      name = "health-check-${name}";
      text = ''
        def main [] {
          let home = ($env.HOME? | default "")
          if $home != "" {
            $env.PATH = [$"($home)/.local/bin"] ++ $env.PATH
          }

          let plan_data = (open ${fleet.plan} | from json)
          let nodes = $plan_data.order

          print $"[${name}] removing any pre-existing VMs: ($nodes | str join ', ')"
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

  exampleProcesses = lib.mapAttrs (_name: lifecycle: {
    command = lib.getExe lifecycle;
    availability.restart = "no";
  }) lifecycles;

  doneProcess = {
    command = "${lib.getExe' pkgs.coreutils "true"}";
    depends_on = lib.mapAttrs (_name: _: {
      condition = "process_completed";
    }) lifecycles;
    availability = {
      restart = "no";
      exit_on_end = true;
    };
  };

  config = {
    version = "0.5";
    processes = exampleProcesses // {
      _done = doneProcess;
    };
  };

  configFile = yamlFormat.generate "health-checks-process-compose.yaml" config;
in
writeNushellApplication pkgs {
  name = "health-checks";
  runtimeInputs = [ pkgs.process-compose ];
  text = ''
    def --wrapped main [...args] {
      exec ${lib.getExe pkgs.process-compose} -f ${configFile} up ...$args
    }
  '';
}
