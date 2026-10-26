{ pkgs }:
let
  inherit (pkgs) lib;
  source = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../shell.qml
      ../Spring.qml
      ../Theme.qml
      ../fonts
      ../backend.py
      ../launch.sh
      ../pyproject.toml
      ../uv.lock
    ];
  };
  runtimePackages = with pkgs; [
    bash
    coreutils
    util-linux
    quickshell
    uv
    python312
    glib
    shared-mime-info
    poppler-utils
    xdg-utils
  ];
  libraryPath = lib.makeLibraryPath [ pkgs.stdenv.cc.cc.lib pkgs.zlib ];
  # Reuse the environment across code changes; renew it when Python or deps change.
  environmentId = builtins.substring 0 16 (builtins.hashString "sha256"
    "${pkgs.python312}:${builtins.hashFile "sha256" ../uv.lock}");

  package = pkgs.writeShellApplication {
    name = "applesearch";
    runtimeInputs = runtimePackages;
    text = ''
      export UV_PYTHON=${pkgs.python312}/bin/python3
      export UV_PYTHON_DOWNLOADS=never
      export XDG_DATA_DIRS="''${XDG_DATA_DIRS:-/usr/local/share:/usr/share}:${pkgs.shared-mime-info}/share"
      export UV_PROJECT_ENVIRONMENT="''${XDG_CACHE_HOME:-$HOME/.cache}/applesearch/venv-${environmentId}"
      export LD_LIBRARY_PATH="${libraryPath}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
      exec ${pkgs.bash}/bin/bash ${source}/launch.sh "$@"
    '';
    passthru.sourcePath = source;
    meta = {
      description = "Local semantic file and application search using Quickshell";
      mainProgram = "applesearch";
      platforms = lib.platforms.linux;
    };
  };
in {
  inherit package;

  shell = pkgs.mkShellNoCC {
    packages = runtimePackages ++ [ package ];
    UV_PYTHON = "${pkgs.python312}/bin/python3";
    UV_PYTHON_DOWNLOADS = "never";
    shellHook = ''
      export LD_LIBRARY_PATH="${libraryPath}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    '';
  };
}
