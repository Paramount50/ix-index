{ lib, beamPackages }:

# Hand-maintained Hex dependency set. `mix2nix mix.lock` produces a working
# `deps.nix` but emits `rec { ... }` per package and a `with self;`/`overrides`
# scaffold that this repo's lint bans (`nix-rules/no-rec-attrset.yml`, plus
# unused lambda args caught by deadnix). The dep graph here is small enough
# that hand-maintaining it is cheaper than wrapping the generator output, and
# `lib.fix` gives the same forward-reference behaviour `rec` provided.
#
# Bumping a dep: edit `mix.exs`/`mix.lock`, then run
# `nix shell nixpkgs#mix2nix -c mix2nix mix.lock` as a hint for the new
# `sha256`, and update the matching entry below.

let
  inherit (beamPackages) buildMix buildRebar3 fetchHex;

  mkHex =
    {
      builder ? buildMix,
      pname,
      version,
      sha256,
      beamDeps ? [ ],
    }:
    builder {
      name = pname;
      inherit version beamDeps;
      src = fetchHex {
        pkg = pname;
        inherit version sha256;
      };
    };
in
lib.fix (self: {
  bandit = mkHex {
    pname = "bandit";
    version = "1.11.1";
    sha256 = "d4401016df9abbc6dcd325c0b78b2b193e7c7c96bb68f31e576112be025d84a5";
    beamDeps = [
      self.hpax
      self.plug
      self.telemetry
      self.thousand_island
      self.websock
    ];
  };

  hpax = mkHex {
    pname = "hpax";
    version = "1.0.3";
    sha256 = "8eab6e1cfa8d5918c2ce4ba43588e894af35dbd8e91e6e55c817bca5847df34a";
  };

  mime = mkHex {
    pname = "mime";
    version = "2.0.7";
    sha256 = "6171188e399ee16023ffc5b76ce445eb6d9672e2e241d2df6050f3c771e80ccd";
  };

  plug = mkHex {
    pname = "plug";
    version = "1.19.2";
    sha256 = "b6fce20a56af5e60fa5dfecf3f907bb98ec981be43c79a3809a499bc3d133de0";
    beamDeps = [
      self.mime
      self.plug_crypto
      self.telemetry
    ];
  };

  plug_crypto = mkHex {
    pname = "plug_crypto";
    version = "2.1.1";
    sha256 = "6470bce6ffe41c8bd497612ffde1a7e4af67f36a15eea5f921af71cf3e11247c";
  };

  telemetry = mkHex {
    builder = buildRebar3;
    pname = "telemetry";
    version = "1.4.2";
    sha256 = "928f6495066506077862c0d1646609eed891a4326bee3126ba54b60af61febb1";
  };

  thousand_island = mkHex {
    pname = "thousand_island";
    version = "1.4.3";
    sha256 = "6e4ce09b0fd761a58594d02814d40f77daff460c48a7354a15ab353bb998ea0b";
    beamDeps = [ self.telemetry ];
  };

  websock = mkHex {
    pname = "websock";
    version = "0.5.3";
    sha256 = "6105453d7fac22c712ad66fab1d45abdf049868f253cf719b625151460b8b453";
  };

  websock_adapter = mkHex {
    pname = "websock_adapter";
    version = "0.6.0";
    sha256 = "50021a85bce8f203b086705d9e0c5415e2c7eb05d319111b0428fe71f9934617";
    beamDeps = [
      self.bandit
      self.plug
      self.websock
    ];
  };
})
