{
  lib,
  stdenvNoCC,
  makeWrapper,
  coreutils,
  util-linux,
  quickshell,
  version ? "unstable",
}:
stdenvNoCC.mkDerivation {
  pname = "aial";
  inherit version;

  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../shell.qml
      ../Config.qml
      ../Spring.qml
      ../Theme.qml
      ../rofi-search.js
      ../launch.sh
      ../fonts
      ../licenses
      ../LICENSE
    ];
  };

  nativeBuildInputs = [ makeWrapper ];

  dontConfigure = true;
  dontBuild = true;

  # launch.sh finds its QML next to itself, so it stays in share/aial and the
  # command is a wrapper that puts Quickshell, flock and setsid on PATH.
  installPhase = ''
    runHook preInstall

    mkdir -p $out/share/aial $out/bin
    cp -r shell.qml Config.qml Spring.qml Theme.qml rofi-search.js launch.sh fonts licenses LICENSE $out/share/aial/
    makeWrapper $out/share/aial/launch.sh $out/bin/aial \
      --prefix PATH : ${
        lib.makeBinPath [
          coreutils
          util-linux
          quickshell
        ]
      }

    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck

    $out/bin/aial --help | grep -q 'Usage:'

    runHook postInstallCheck
  '';

  meta = {
    description = "Spotlight-style application launcher for Quickshell";
    homepage = "https://github.com/Kalkaro/aial";
    license = with lib.licenses; [
      mit
      ofl
    ];
    mainProgram = "aial";
    platforms = lib.platforms.linux;
  };
}
