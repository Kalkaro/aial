{
  description = "Spotlight-style application launcher for Quickshell";

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
        aial = (runtimeFor system).package;
      });

      apps = forEachSystem (system: {
        default = {
          type = "app";
          program = "${(runtimeFor system).package}/bin/aial";
          meta.description = "Open the Spotlight-style launcher panel";
        };
      });

      devShells = forEachSystem (system: {
        default = (runtimeFor system).shell;
      });
    };
}
