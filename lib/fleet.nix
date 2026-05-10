# Colmena-style fleet evaluation for ix images.
{
  lib,
  pkgs,
  evalImageConfig,
}:
{
  defaults ? [ ],
  deployment ? { },
  secrets ? { },
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
    bootstrapImage = "registry.ix.dev/ix/test-cluster-bootstrap:a00f95b4a00a07fa";
    region = "hil-1";
    ipv4 = false;
    snapshot = true;
    switch.buildOn = "remote";
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
      replicas = spec.replicas or 1;
    };

  expandReplicas =
    name: spec:
    assert lib.assertMsg (
      builtins.isInt spec.replicas && spec.replicas > 0
    ) "fleet node '${name}': replicas must be a positive integer";
    if spec.replicas == 1 then
      {
        ${name} = spec // {
          baseName = name;
        };
      }
    else
      builtins.listToAttrs (
        lib.genList (index: {
          name = "${name}-${toString index}";
          value = spec // {
            name = "${name}-${toString index}";
            baseName = name;
            replicaIndex = index;
          };
        }) spec.replicas
      );

  rawNodeSpecs = lib.mapAttrs normalizeNode nodes;
  nodeSpecs = lib.foldl' (acc: name: acc // expandReplicas name rawNodeSpecs.${name}) { } (
    builtins.attrNames rawNodeSpecs
  );
  expandDependency =
    dep:
    if builtins.hasAttr dep rawNodeSpecs then
      if rawNodeSpecs.${dep}.replicas == 1 then
        [ dep ]
      else
        lib.genList (index: "${dep}-${toString index}") rawNodeSpecs.${dep}.replicas
    else
      [ dep ];

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
      replacementDestination = deploy.destination or "${imageName}:${imageTag}";
      switchTarget =
        deploy.switch.target or builtins.unsafeDiscardStringContext
          config.system.build.toplevel.drvPath;
      switchBuildOn = deploy.switch.buildOn or "remote";
    in
    {
      inherit
        name
        ;
      baseName = spec.baseName;
      replicaIndex = spec.replicaIndex or null;
      system = builtins.unsafeDiscardStringContext "${config.system.build.toplevel}";
      switch = {
        target = switchTarget;
        buildOn = switchBuildOn;
        sourceInstallable = deploy.switch.sourceInstallable or ".#${name}-system";
        overrideInputs = deploy.switch.overrideInputs or { };
      };
      bootstrapImage = deploy.bootstrapImage;
      replacementImage = {
        inherit
          imageName
          imageTag
          ;
        destination = replacementDestination;
        source = builtins.unsafeDiscardStringContext "${config.ix.build.ociImage}";
        sourceDrv = builtins.unsafeDiscardStringContext config.ix.build.ociImage.drvPath;
      };
      region = deploy.region;
      ipv4 = deploy.ipv4;
      snapshot = deploy.snapshot;
      tags = spec.tags;
      env = deploy.env;
      l7ProxyPorts = deploy.l7ProxyPorts;
      dependsOn = lib.concatMap expandDependency spec.dependsOn;
    }
  ) nodeSpecs;

  planValue = {
    order = builtins.attrNames nodeSpecs;
    nodes = nodePlan;
    inherit secrets;
  };

  plan = pkgs.writeText "ix-fleet-plan.json" (builtins.toJSON planValue);
  python = pkgs.python3.withPackages (ps: [ ps.pydantic ]);
  command = pkgs.writeShellApplication {
    name = "ix-fleet";
    runtimeInputs = [ python ];
    text = ''exec python3 ${../tools/ix-fleet.py} --plan ${plan} "$@"'';
  };
  switch = pkgs.writeShellApplication {
    name = "ix-fleet-switch";
    runtimeInputs = [ python ];
    text = ''exec python3 ${../tools/ix-fleet.py} --plan ${plan} switch "$@"'';
  };

in
{
  inherit
    command
    plan
    switch
    ;

  inherit planValue;
  nodes = nodeConfigs;
  meta = nodeSpecs;
  packages = lib.mapAttrs (name: config: config.ix.build.ociImage) nodeConfigs;
  systemPackages = lib.mapAttrs' (
    name: config: lib.nameValuePair "${name}-system" config.system.build.toplevel
  ) nodeConfigs;
}
