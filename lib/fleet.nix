# Colmena-style fleet evaluation for ix images.
{
  lib,
  pkgs,
  evalImageConfig,
}:
{
  defaults ? [ ],
  deployment ? { },
  nodes,
}:
let
  asList = value: if builtins.isList value then value else [ value ];

  moduleList =
    spec:
    if spec ? modules then
      asList spec.modules
    else if spec ? module then
      asList spec.module
    else
      [ ];

  deploymentDefaults = {
    region = "hil-1";
    ipv4 = false;
    replace = true;
  };

  mergeDeployments =
    parts:
    let
      merged = lib.foldl' (acc: part: acc // part) { } parts;
      env = lib.foldl' (acc: part: acc // (part.env or { })) { } parts;
      l7ProxyPorts = lib.unique (lib.concatMap (part: part.l7ProxyPorts or [ ]) parts);
    in
    merged // { inherit env l7ProxyPorts; };

  isWrappedNode = value: builtins.isAttrs value && (value ? module || value ? modules);

  normalizeNode =
    name: value:
    let
      spec = if isWrappedNode value then value else { modules = [ value ]; };
      deploymentParts = [
        deploymentDefaults
        deployment
      ]
      ++ [
        (spec.deployment or { })
      ];
    in
    {
      inherit name;
      modules = asList defaults ++ moduleList spec;
      tags = lib.unique (asList (spec.tags or [ ]));
      deployment = mergeDeployments deploymentParts;
      dependsOn = asList (spec.dependsOn or [ ]);
    };

  nodeSpecs = lib.mapAttrs normalizeNode nodes;

  nodeConfigs = lib.mapAttrs (
    name: spec:
    evalImageConfig {
      modules = [
        {
          _module.args = {
            inherit name;
            nodes = nodeRefs;
            fleet.nodes = nodeRefs;
          };

          ix.image.name = lib.mkDefault name;
          networking.hostName = lib.mkDefault name;
        }
      ]
      ++ spec.modules;
    }
  ) nodeSpecs;

  nodeRefs = lib.mapAttrs (_name: config: { inherit config; }) nodeConfigs;

  nodePlan = lib.mapAttrs (
    name: spec:
    let
      config = nodeConfigs.${name};
      imageName = config.ix.image.name;
      imageTag = config.ix.image.tag;
      deploy = spec.deployment;
      destination = deploy.destination or "${imageName}:${imageTag}";
    in
    {
      inherit
        name
        imageName
        imageTag
        destination
        ;
      source = "${config.ix.build.ociImage}";
      region = deploy.region;
      ipv4 = deploy.ipv4;
      replace = deploy.replace;
      tags = spec.tags;
      env = deploy.env;
      l7ProxyPorts = deploy.l7ProxyPorts;
      dependsOn = spec.dependsOn;
    }
  ) nodeSpecs;

  planValue = {
    order = builtins.attrNames nodeSpecs;
    nodes = nodePlan;
  };

  plan = pkgs.writeText "ix-fleet-plan.json" (builtins.toJSON planValue);

in
{
  inherit plan;

  inherit planValue;
  nodes = nodeConfigs;
  meta = nodeSpecs;
  packages = lib.mapAttrs (name: config: config.ix.build.ociImage) nodeConfigs;
}
