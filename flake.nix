{
  description = "Spotlight-style application launcher for Quickshell";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forEachSystem = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
      version = self.shortRev or self.dirtyShortRev or "unstable";
      runtimeFor = pkgs: import ./nix/runtime.nix { inherit pkgs version; };
    in
    {
      packages = forEachSystem (pkgs: {
        default = (runtimeFor pkgs).package;
        aial = (runtimeFor pkgs).package;
      });

      apps = forEachSystem (pkgs: {
        default = {
          type = "app";
          program = "${(runtimeFor pkgs).package}/bin/aial";
          meta.description = "Open the Spotlight-style launcher panel";
        };
      });

      devShells = forEachSystem (pkgs: {
        default = (runtimeFor pkgs).shell;
      });

      overlays.default = final: _prev: {
        aial = final.callPackage ./nix/package.nix { inherit version; };
      };

      # programs.aial, for Home Manager.
      homeModules.default = import ./nix/home-manager.nix { inherit self; };
      homeManagerModules = self.homeModules;

      checks = forEachSystem (pkgs: import ./nix/checks.nix { inherit self pkgs; });

      formatter = forEachSystem (pkgs: pkgs.nixfmt);
    };
}
