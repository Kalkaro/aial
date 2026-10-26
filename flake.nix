{
  description = "Local EmbeddingGemma 2 Spotlight for Quickshell";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { nixpkgs, ... }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forEachSystem = nixpkgs.lib.genAttrs systems;
      runtimeFor = system: import ./nix/runtime.nix {
        pkgs = import nixpkgs { inherit system; };
      };
    in {
      packages = forEachSystem (system: {
        default = (runtimeFor system).package;
        applesearch = (runtimeFor system).package;
      });

      apps = forEachSystem (system: {
        default = {
          type = "app";
          program = "${(runtimeFor system).package}/bin/applesearch";
          meta.description = "Open the local Spotlight search panel";
        };
      });

      devShells = forEachSystem (system: {
        default = (runtimeFor system).shell;
      });
    };
}
