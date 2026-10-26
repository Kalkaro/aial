import QtQuick
import Quickshell
import Quickshell.Io

QtObject {
    id: theme

    readonly property string path: Quickshell.env("APPLESEARCH_PALETTE")
        || (Quickshell.env("XDG_CONFIG_HOME") || Quickshell.env("HOME") + "/.config") + "/stylix/palette.json"
    property var colors: ({})

    // Base16 defaults keep the app usable when Stylix is not installed.
    readonly property color base00: colors.base00 || "#181818"
    readonly property color base01: colors.base01 || "#282828"
    readonly property color base02: colors.base02 || "#383838"
    readonly property color base03: colors.base03 || "#585858"
    readonly property color base04: colors.base04 || "#b8b8b8"
    readonly property color base05: colors.base05 || "#d8d8d8"
    readonly property color base06: colors.base06 || "#e8e8e8"
    readonly property color base07: colors.base07 || "#f8f8f8"
    readonly property color base08: colors.base08 || "#ab4642"
    readonly property color base09: colors.base09 || "#dc9656"
    readonly property color base0A: colors.base0A || "#f7ca88"
    readonly property color base0B: colors.base0B || "#a1b56c"
    readonly property color base0C: colors.base0C || "#86c1b9"
    readonly property color base0D: colors.base0D || "#7cafc2"
    readonly property color base0E: colors.base0E || "#ba8baf"
    readonly property color base0F: colors.base0F || "#a16946"
    readonly property bool dark: base00.r * 0.2126 + base00.g * 0.7152 + base00.b * 0.0722 < 0.5

    function load(text) {
        try {
            let source = JSON.parse(text);
            let next = Object.assign({}, colors);
            for (let i = 0; i < 16; ++i) {
                let key = "base0" + i.toString(16).toUpperCase();
                let value = source[key] || source[key.toLowerCase()];
                if (typeof value === "string" && /^#?[0-9a-f]{6}$/i.test(value.trim()))
                    next[key] = "#" + value.trim().replace(/^#/, "").toLowerCase();
            }
            colors = next;
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
        onFileChanged: reload()
    }

    Component.onCompleted: load(paletteFile.text())
}
