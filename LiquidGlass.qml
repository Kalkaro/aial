pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import QtQml.Models
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland

// MacShell's refraction shader and pre-blurred backdrop, adapted for one panel.
// No full-shell services or persistent screen/clipboard recordings are imported.
Item {
    id: glass

    required property var screen
    required property string sourceDirectory
    property Theme palette: null
    readonly property color tintColor: palette ? palette.base00 : "#181818"
    readonly property bool dark: palette ? palette.dark : true
    property bool active: false
    property real screenX: 0
    property real screenY: 0
    property real viewportHeight: height
    property real cornerRadius: 22
    // A visual scale applied by an ancestor around scaleOrigin, in glass coordinates.
    property real displayScale: 1
    property point scaleOrigin: Qt.point(width / 2, height / 2)
    property url shaderUrl: localUrl(Quickshell.env("APPLESEARCH_GLASS_SHADER"))
    property string shaderError: ""
    property string wallpaperPath: Quickshell.env("APPLESEARCH_WALLPAPER")
    property int wallpaperProvider: 0
    property int geometrySerial: 0
    property var firstSeen: ({})
    readonly property bool ready: shaderUrl.toString().length > 0 && refraction.status === ShaderEffect.Compiled
    readonly property int windowCount: windowModel.count
    readonly property real backdropMargin: 80
    readonly property bool isHyprland: Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE").length > 0
    readonly property var hyprlandMonitor: isHyprland && screen ? Hyprland.monitorFor(screen) : null
    readonly property int workspaceId: hyprlandMonitor?.activeWorkspace?.id ?? 0
    readonly property int specialWorkspaceId: hyprlandMonitor?.lastIpcObject?.specialWorkspace?.id ?? 0
    readonly property bool workspaceAnimating: workspaceMotion.moving
    readonly property bool workspaceAnimationReady: Object.keys(workspaceMotion.animationNodes).length > 0
    readonly property bool windowAnimating: windowMotion.moving
    readonly property int monitorX: hyprlandMonitor?.lastIpcObject?.x || 0
    readonly property int monitorY: hyprlandMonitor?.lastIpcObject?.y || 0

    WorkspaceMotion {
        id: workspaceMotion
        active: glass.active
        supported: glass.isHyprland
        screenSize: Qt.size(glass.screen?.width || 0, glass.screen?.height || 0)
        monitorName: glass.screen?.name || ""
        workspaceId: glass.workspaceId
        specialWorkspaceId: glass.specialWorkspaceId
        onChanged: Qt.callLater(glass.syncGeometry)
    }

    WindowMotion {
        id: windowMotion
        configuration: workspaceMotion
        active: glass.active
        onChanged: Qt.callLater(glass.syncGeometry)
    }

    function observeWindows() {
        let clients = Hyprland.toplevels.values.map(toplevel => toplevel.lastIpcObject);
        let seen = {}, now = Date.now();
        for (let client of clients)
            if (client?.mapped && client.address)
                seen[client.address] = firstSeen[client.address] || now;
        firstSeen = seen;
        windowMotion.update(clients);
    }

    // Keep only geometry metadata while hidden, so opening mid-animation resumes it.
    Instantiator {
        model: glass.isHyprland ? Hyprland.toplevels.values : []
        onObjectRemoved: Qt.callLater(glass.observeWindows)
        delegate: Connections {
            required property var modelData
            target: modelData
            function onLastIpcObjectChanged() { Qt.callLater(glass.observeWindows); }
            Component.onCompleted: Qt.callLater(glass.observeWindows)
        }
    }
    Connections {
        target: Hyprland
        function onRawEvent(event) {
            if (event.name === "fullscreen") {
                windowMotion.fullscreenEvent = Date.now();
                Hyprland.refreshToplevels();
            }
        }
    }

    function localUrl(path) {
        path = path || "";
        if (path.startsWith("file:///"))
            return path;
        if (path.startsWith("~/"))
            path = Quickshell.env("HOME") + path.substring(1);
        // Only local absolute paths can become an image/shader source.
        return path.startsWith("/") ? "file://" + encodeURI(path).replace(/#/g, "%23").replace(/\?/g, "%3F") : "";
    }

    function refreshWallpaper() {
        if (!active || Quickshell.env("APPLESEARCH_WALLPAPER") || wallpaperProbe.running)
            return;
        wallpaperProvider = 0;
        wallpaperProbe.running = true;
    }

    function readWallpaper(text) {
        let fallback = "";
        for (let line of text.split("\n")) {
            let separator = wallpaperProvider === 0 ? line.indexOf(": ") : line.indexOf("image: ");
            if (separator < 0)
                continue;
            let path = line.substring(separator + (wallpaperProvider === 0 ? 2 : 7)).trim();
            if (!localUrl(path))
                continue;
            if (!fallback)
                fallback = path;
            if (line.substring(0, separator).startsWith(screen.name + ":")) {
                wallpaperPath = path;
                return true;
            }
            // hyprpaper uses "monitor: path", while swww/awww include details.
            if (wallpaperProvider === 0 && line.substring(0, separator) === screen.name) {
                wallpaperPath = path;
                return true;
            }
        }
        if (fallback)
            wallpaperPath = fallback;
        return fallback.length > 0;
    }

    function sourceFor(address) {
        // React to both protocol object changes and the delayed admission tick.
        let serial = geometrySerial;
        if (Date.now() - (firstSeen[address] || Date.now()) < 200)
            return null;
        for (let toplevel of Hyprland.toplevels.values) {
            if (toplevel.address.replace(/^0x/, "") === address.replace(/^0x/, ""))
                return toplevel.wayland;
        }
        return null;
    }

    function syncGeometry() {
        if (!active || !isHyprland)
            return;
        let monitor = hyprlandMonitor?.lastIpcObject;
        if (!monitor || workspaceId === 0)
            return;
        let wanted = {};
        let seen = {};
        for (let toplevel of Hyprland.toplevels.values) {
            let client = toplevel.lastIpcObject;
            if (!client?.address || !client.at || !client.size)
                continue;
            seen[client.address] = firstSeen[client.address] || Date.now();
            if (!client.mapped || client.hidden || client.monitor !== monitor.id
                || !client.pinned && !workspaceMotion.includes(client.workspace?.id))
                continue;
            // Mapped windows can still be obscured by a maximized/fullscreen one.
            // Keep departing workspaces until their slide/fade has finished.
            if (client.visible === false && windowMotion.alpha(client.address) <= 0.001
                && !workspaceMotion.transitions[client.workspace?.id])
                continue;
            let extent = windowMotion.bounds(client.address, Qt.rect(client.at[0], client.at[1], client.size[0], client.size[1]));
            let x = extent.x - monitor.x;
            let y = extent.y - monitor.y;
            let intersects = workspaceMotion.transitions[client.workspace?.id] !== undefined
                || !(x + extent.width < screenX - backdropMargin || x > screenX + width + backdropMargin
                     || y + extent.height < screenY - backdropMargin || y > screenY + Math.max(height, viewportHeight) + backdropMargin);
            wanted[client.address] = {address: client.address, px: client.at[0] - monitor.x, py: client.at[1] - monitor.y,
                                     pw: client.size[0], ph: client.size[1],
                                     intersects: intersects,
                                     workspace: client.workspace.id, pinned: !!client.pinned,
                                     special: (client.workspace.name || "").startsWith("special:"),
                                     // The compositor's internal state controls stacking;
                                     // fullscreenClient only describes what the app was told.
                                     stack: client.fullscreen > 0 || windowMotion.resizing(client.address) ? 2000
                                            : client.floating ? (client.pinned || client.allowedOverFullscreen ? 3000 : 1000)
                                              - Math.min(Math.max(client.focusHistoryID, 0), 999) : 0,
                                     gone: false};
        }
        firstSeen = seen;
        for (let i = windowModel.count - 1; i >= 0; --i) {
            let address = windowModel.get(i).address;
            if (wanted[address]) {
                windowModel.set(i, wanted[address]);
                delete wanted[address];
            } else if (!windowModel.get(i).gone) {
                windowModel.setProperty(i, "gone", true);
                sweep.restart();
            }
        }
        for (let address in wanted)
            windowModel.append(wanted[address]);
        ++geometrySerial;
    }

    onActiveChanged: {
        if (active) {
            refreshWallpaper();
            if (isHyprland) {
                Hyprland.refreshMonitors();
                Hyprland.refreshToplevels();
                syncGeometry();
            }
        }
    }
    onScreenChanged: if (active) { refreshWallpaper(); syncGeometry(); }

    Process {
        id: shaderCompiler
        command: [glass.sourceDirectory + "/launch.sh", "--shader"]
        running: !glass.shaderUrl.toString().length
        stdout: StdioCollector {
            onStreamFinished: {
                if (text.trim())
                    glass.shaderUrl = glass.localUrl(text.trim());
            }
        }
        stderr: StdioCollector {
            onStreamFinished: if (text.trim()) console.warn("AppleSearch glass: " + text.trim())
        }
    }

    Process {
        id: wallpaperProbe
        command: glass.wallpaperProvider === 0 ? ["hyprctl", "hyprpaper", "listactive"]
               : [glass.wallpaperProvider === 1 ? "swww" : "awww", "query"]
        stdout: StdioCollector { id: wallpaperOutput }
        onExited: {
            if (!glass.readWallpaper(wallpaperOutput.text) && glass.wallpaperProvider < 2 && glass.active) {
                ++glass.wallpaperProvider;
                wallpaperRetry.restart();
            }
        }
    }
    Timer { id: wallpaperRetry; interval: 1; onTriggered: if (glass.active) wallpaperProbe.running = true }
    Timer { interval: 15000; repeat: true; running: glass.active; onTriggered: glass.refreshWallpaper() }
    Timer {
        interval: 33
        repeat: true
        running: glass.active && glass.ready && glass.isHyprland
        onTriggered: {
            Hyprland.refreshMonitors();
            Hyprland.refreshToplevels();
            glass.syncGeometry();
        }
    }
    Timer {
        id: sweep
        interval: 600
        onTriggered: {
            for (let i = windowModel.count - 1; i >= 0; --i)
                if (windowModel.get(i).gone) windowModel.remove(i);
        }
    }
    ListModel { id: windowModel }

    Item {
        id: backdrop
        width: glass.width + 2 * glass.backdropMargin
        // A fixed texture extent prevents resampling/reallocation during resize.
        height: Math.max(glass.height, glass.viewportHeight) + 2 * glass.backdropMargin
        visible: false

        Rectangle { anchors.fill: parent; color: glass.tintColor }
        Image {
            x: glass.backdropMargin - glass.screenX
            y: glass.backdropMargin - glass.screenY
            width: glass.screen?.width || 1
            height: glass.screen?.height || 1
            source: glass.localUrl(glass.wallpaperPath)
            sourceSize.width: width
            sourceSize.height: height
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
        }
        Repeater {
            model: windowModel
            delegate: Item {
                id: capturedWindow
                required property string address
                required property real px
                required property real py
                required property real pw
                required property real ph
                required property real stack
                required property bool gone
                required property int workspace
                required property bool pinned
                required property bool special
                required property bool intersects
                property bool reconnecting: false
                readonly property var motion: pinned ? {x: 0, y: 0, alpha: 1} : workspaceMotion.transform(workspace)
                readonly property rect rectangle: windowMotion.rectangle(address, Qt.rect(px + glass.monitorX, py + glass.monitorY, pw, ph))
                x: rectangle.x - glass.monitorX - glass.screenX + glass.backdropMargin + motion.x
                y: rectangle.y - glass.monitorY - glass.screenY + glass.backdropMargin + motion.y
                width: rectangle.width
                height: rectangle.height
                z: (special ? 20000 : 0) + stack
                opacity: !gone && (pinned || workspaceMotion.includes(workspace)) ? motion.alpha * windowMotion.alpha(address) : 0

                function cacheFrame() {
                    if (capture.hasContent && frameCache.item && (!windowMotion.resizing(address) || !frameCache.item.ready)) {
                        frameCache.item.sourceRect = Qt.rect(0, 0, capture.width, capture.height);
                        frameCache.item.textureSize = Qt.size(Math.max(1, Math.ceil(capture.width / 2)),
                                                              Math.max(1, Math.ceil(capture.height / 2)));
                        frameCache.item.scheduleUpdate();
                        frameCache.item.ready = true;
                    }
                }

                ScreencopyView {
                    id: capture
                    width: capturedWindow.pw
                    height: capturedWindow.ph
                    captureSource: !glass.active || capturedWindow.gone || capturedWindow.reconnecting
                                   ? null : glass.sourceFor(capturedWindow.address)
                    constraintSize: Qt.size(Math.max(1, capturedWindow.width / 2), Math.max(1, capturedWindow.height / 2))
                    paintCursor: false
                    live: false
                    onHasContentChanged: if (hasContent) Qt.callLater(capturedWindow.cacheFrame)
                }
                // Keep one frame per visible window for resize animations. Offscreen
                // windows do not stream; textures are destroyed when the panel hides.
                Loader {
                    id: frameCache
                    anchors.fill: parent
                    active: glass.active && !capturedWindow.gone
                    sourceComponent: ShaderEffectSource {
                        property bool ready: false
                        sourceItem: capture
                        hideSource: true
                        live: false
                        Component.onCompleted: Qt.callLater(capturedWindow.cacheFrame)
                    }
                }
                Connections {
                    target: windowMotion
                    function onChanged() { Qt.callLater(capturedWindow.cacheFrame); }
                }
                // Only intersecting windows stream, targeting 60 fps while open.
                Timer {
                    interval: 16
                    repeat: true
                    running: glass.active && glass.ready && capture.hasContent
                             && capturedWindow.intersects
                             && (capturedWindow.pinned || !workspaceMotion.exiting(capturedWindow.workspace))
                    onTriggered: {
                        capturedWindow.cacheFrame();
                        capture.captureFrame();
                    }
                }
                // Hyprland can invalidate an export during a resize or remap.
                // A non-null source then has no recording context until rebound.
                Timer {
                    interval: windowMotion.resizing(capturedWindow.address) ? 33 : 500
                    repeat: true
                    running: glass.active && glass.ready && !capturedWindow.gone
                    onTriggered: if (capture.captureSource !== null && !capture.hasContent) {
                        capturedWindow.reconnecting = true;
                        reconnect.restart();
                    }
                }
                Timer {
                    id: reconnect
                    interval: windowMotion.resizing(capturedWindow.address) ? 1 : 100
                    onTriggered: capturedWindow.reconnecting = false
                }
            }
        }
    }

    ShaderEffectSource {
        id: backdropTexture
        sourceItem: backdrop
        // Zoom by the inverse of displayScale, so scaled glass still refracts
        // what is directly behind it.
        sourceRect: Qt.rect((glass.backdropMargin + glass.scaleOrigin.x) * (1 - glass.displayScale),
                            (glass.backdropMargin + glass.scaleOrigin.y) * (1 - glass.displayScale),
                            backdrop.width * glass.displayScale, backdrop.height * glass.displayScale)
        textureSize: Qt.size(Math.max(1, Math.ceil(backdrop.width / 2)), Math.max(1, Math.ceil(backdrop.height / 2)))
        hideSource: true
        live: glass.active
        visible: false
    }
    MultiEffect {
        id: preblur
        source: backdropTexture
        width: backdrop.width / 2
        height: backdrop.height / 2
        blurEnabled: true
        blurMax: 32
        blur: 0.85
        autoPaddingEnabled: false
        visible: false
    }
    ShaderEffectSource {
        id: blurredTexture
        sourceItem: preblur
        mipmap: true
        live: glass.active
        visible: false
    }

    Rectangle {
        anchors.fill: parent
        visible: !glass.ready
        radius: glass.cornerRadius
        color: Qt.alpha(glass.tintColor, 0.90)
        border.width: 0
    }
    ShaderEffect {
        id: refraction
        x: -10
        y: -10
        width: glass.width + 20
        height: glass.height + 20
        visible: glass.shaderUrl.toString().length > 0
        fragmentShader: glass.shaderUrl
        onStatusChanged: if (status === ShaderEffect.Error) {
            glass.shaderError = log;
            console.warn("AppleSearch glass shader: " + log);
        }
        property variant src: blurredTexture
        // Qt's default shader can briefly be active while the cached URL loads.
        property variant source: blurredTexture
        property vector2d itemSize: Qt.vector2d(width, height)
        property vector2d glassSize: Qt.vector2d(glass.width, glass.height)
        property vector2d srcSize: Qt.vector2d(backdrop.width, backdrop.height)
        property vector2d srcOffset: Qt.vector2d(glass.backdropMargin - 10, glass.backdropMargin - 10)
        property real pad: 10
        property real radius: glass.cornerRadius
        property real bezel: Math.min(glass.height * 0.36, 26)
        property real thickness: 34
        property real dispersion: 0.065
        property real blurPx: 1.5
        property real tintMix: 0.48
        property color tintColor: glass.tintColor
        property real saturation: 1.18
        property real dark: glass.dark ? 1 : 0
        property real debug: 0
        property real rim: 0.12
        property real grain: 0.004
        // Refraction stays at the edges; center-based magnification drifts on resize.
        property real magnify: 0
        property real shadowAmt: 0.7
        property real rimTint: 0
        property real ringW: 0
    }
}
