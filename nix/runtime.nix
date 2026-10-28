{ pkgs }:
let
  inherit (pkgs) lib;
  source = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../shell.qml
      ../Spring.qml
      ../Theme.qml
      ../rofi-search.js
      ../fonts
      ../licenses
      ../launch.sh
    ];
  };
  runtimePackages = with pkgs; [
    bash
    coreutils
    util-linux
    quickshell
  ];

  package = pkgs.writeShellApplication {
    name = "aial";
    runtimeInputs = runtimePackages;
    text = ''
      exec ${pkgs.bash}/bin/bash ${source}/launch.sh "$@"
    '';
    passthru.sourcePath = source;
    meta = {
      description = "Spotlight-style application launcher for Quickshell";
      mainProgram = "aial";
      platforms = lib.platforms.linux;
    };
  };
in {
  inherit package;

  shell = pkgs.mkShellNoCC {
    # Node.js and Python run the tests.
    packages = runtimePackages ++ [ package pkgs.nodejs pkgs.python3 ];
  };
}
