import QtQuick
import Quickshell
import Quickshell.Io

QtObject {
    id: theme

    // The palette file: the environment, then config.json's palette, then Stylix's.
    property string palettePath: ""
    // Colors from config.json, which win over the palette file.
    property var overrides: ({})
    readonly property string path: Quickshell.env("APPLESEARCH_PALETTE") || palettePath
        || (Quickshell.env("XDG_CONFIG_HOME") || Quickshell.env("HOME") + "/.config") + "/stylix/palette.json"
    property var colors: ({})
    readonly property var merged: Object.assign({}, colors, valid(overrides))

    // Base16 defaults keep the app usable when Stylix is not installed.
    readonly property color base00: merged.base00 || "#181818"
    readonly property color base01: merged.base01 || "#282828"
    readonly property color base02: merged.base02 || "#383838"
    readonly property color base03: merged.base03 || "#585858"
    readonly property color base04: merged.base04 || "#b8b8b8"
    readonly property color base05: merged.base05 || "#d8d8d8"
    readonly property color base06: merged.base06 || "#e8e8e8"
    readonly property color base07: merged.base07 || "#f8f8f8"
    readonly property color base08: merged.base08 || "#ab4642"
    readonly property color base09: merged.base09 || "#dc9656"
    readonly property color base0A: merged.base0A || "#f7ca88"
    readonly property color base0B: merged.base0B || "#a1b56c"
    readonly property color base0C: merged.base0C || "#86c1b9"
    readonly property color base0D: merged.base0D || "#7cafc2"
    readonly property color base0E: merged.base0E || "#ba8baf"
    readonly property color base0F: merged.base0F || "#a16946"
    readonly property bool dark: base00.r * 0.2126 + base00.g * 0.7152 + base00.b * 0.0722 < 0.5

    // The valid base16 colors in a palette, as "#rrggbb" under their uppercase keys.
    function valid(source) {
        let found = {};
        for (let i = 0; i < 16; ++i) {
            let key = "base0" + i.toString(16).toUpperCase();
            let value = source[key] || source[key.toLowerCase()];
            if (typeof value === "string" && /^#?[0-9a-f]{6}$/i.test(value.trim()))
                found[key] = "#" + value.trim().replace(/^#/, "").toLowerCase();
        }
        return found;
    }

    // The file the colors came from. A different one replaces them rather than adding to them.
    property string loadedPath: ""

    function switchFile() {
        if (paletteFile.path === loadedPath)
            return;
        loadedPath = paletteFile.path;
        colors = ({});
    }

    function load(text) {
        switchFile();
        try {
            colors = Object.assign({}, colors, valid(JSON.parse(text)));
        } catch (error) {
            // Retain the last valid palette during partial/invalid file writes.
        }
    }

    function refresh() { paletteFile.reload(); }

    property FileView paletteFile: FileView {
        path: theme.path
        watchChanges: true
        blockLoading: true
        printErrors: false
        onLoaded: theme.load(text())
        onLoadFailed: theme.switchFile()
        onFileChanged: reload()
    }

    Component.onCompleted: load(paletteFile.text())
}
