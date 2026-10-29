{
  pkgs,
  version ? "unstable",
}:
let
  package = pkgs.callPackage ./package.nix { inherit version; };
in
{
  inherit package;

  shell = pkgs.mkShellNoCC {
    # ./launch.sh needs Quickshell, flock and setsid; Node.js and Python run the tests.
    packages = with pkgs; [
      bash
      coreutils
      util-linux
      quickshell
      package
      nodejs
      python3
    ];
  };
}
