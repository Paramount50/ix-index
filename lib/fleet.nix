# Colmena-style fleet evaluation for ix images.
{
  lib,
  pkgs,
  evalImageConfig,
}:
{
  defaults ? [ ],
  deployment ? { },
  groups ? { },
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

  normalizeGroup = name: value: {
    inherit name;
    modules = moduleList value;
    tags = lib.unique ([ name ] ++ asList (value.tags or [ ]));
    deployment = value.deployment or { };
  };

  normalizedGroups = lib.mapAttrs normalizeGroup groups;

  looksStructured =
    value:
    builtins.isAttrs value
    && lib.any (key: builtins.hasAttr key value) [
      "module"
      "modules"
      "group"
      "groups"
      "tags"
      "deployment"
      "dependsOn"
    ];

  normalizeNode =
    name: value:
    let
      spec = if looksStructured value then value else { modules = [ value ]; };
      groupNames = lib.unique (asList (spec.groups or (spec.group or [ ])));
      missingGroups = lib.filter (group: !(builtins.hasAttr group normalizedGroups)) groupNames;
      groupValues = map (group: normalizedGroups.${group}) groupNames;
      groupModules = lib.concatMap (group: group.modules) groupValues;
      groupTags = lib.concatMap (group: group.tags) groupValues;
      deploymentParts = [
        deploymentDefaults
        deployment
      ]
      ++ map (group: group.deployment) groupValues
      ++ [
        (spec.deployment or { })
      ];
    in
    assert lib.assertMsg (
      missingGroups == [ ]
    ) "fleet node '${name}' references unknown groups: ${lib.concatStringsSep ", " missingGroups}";
    {
      inherit name groupNames;
      modules = asList defaults ++ groupModules ++ moduleList spec;
      tags = lib.unique (groupTags ++ asList (spec.tags or [ ]));
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
            fleet = {
              inherit normalizedGroups;
              groups = normalizedGroups;
            };
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
      groups = spec.groupNames;
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
