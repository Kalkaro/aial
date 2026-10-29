let
  lock = builtins.fromJSON (builtins.readFile ./flake.lock);
  pinned = lock.nodes.nixpkgs.locked;
  nixpkgs = builtins.fetchTarball {
    url = "https://github.com/${pinned.owner}/${pinned.repo}/archive/${pinned.rev}.tar.gz";
    sha256 = pinned.narHash;
  };
  pkgs = import nixpkgs {
    config = { };
    overlays = [ ];
  };
in
(import ./nix/runtime.nix { inherit pkgs; }).shell
