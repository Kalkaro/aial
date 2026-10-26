import QtQuick

// IPC geometry is the destination, rather than the compositor's animated rectangle.
QtObject {
    id: motion

    required property WorkspaceMotion configuration
    property bool active: false
    property var windows: ({})
    property double frameTime: Date.now()
    property double fullscreenEvent: 0
    readonly property bool moving: Object.values(windows).some(entry =>
        frameTime < entry.start + entry.duration || frameTime < entry.alphaStart + entry.alphaDuration)
    signal changed()

    function settings(names) {
        for (let name of names) {
            let node = configuration.animationNodes[name];
            if (node?.overridden)
                return node;
        }
        return {enabled: false, speed: 0, bezier: ""};
    }

    function duration(node) {
        return configuration.animationsEnabled && node.enabled ? Math.max(0, Number(node.speed) * 100 || 0) : 0;
    }

    function eased(start, length, curve, now) {
        let progress = length > 0 ? Math.max(0, Math.min(1, (now - start) / length)) : 1;
        return configuration.ease(progress, curve);
    }

    function rectangle(address, fallback, at) {
        let entry = windows[address];
        if (!entry)
            return fallback;
        let t = eased(entry.start, entry.duration, entry.curve, at ?? frameTime);
        return Qt.rect(entry.from.x + (entry.to.x - entry.from.x) * t,
                       entry.from.y + (entry.to.y - entry.from.y) * t,
                       Math.max(1, entry.from.width + (entry.to.width - entry.from.width) * t),
                       Math.max(1, entry.from.height + (entry.to.height - entry.from.height) * t));
    }

    function alpha(address, at) {
        let entry = windows[address];
        if (!entry)
            return 1;
        let t = eased(entry.alphaStart, entry.alphaDuration, entry.alphaCurve, at ?? frameTime);
        return Math.max(0, Math.min(1, entry.alphaFrom + (entry.alphaTo - entry.alphaFrom) * t));
    }

    function resizing(address) {
        let entry = windows[address];
        return entry !== undefined && frameTime < entry.start + entry.duration;
    }

    function bounds(address, fallback) {
        let entry = windows[address];
        if (!entry || !resizing(address))
            return entry?.to ?? fallback;
        let x = Math.min(entry.from.x, entry.to.x), y = Math.min(entry.from.y, entry.to.y);
        return Qt.rect(x, y, Math.max(entry.from.x + entry.from.width, entry.to.x + entry.to.width) - x,
                            Math.max(entry.from.y + entry.from.height, entry.to.y + entry.to.height) - y);
    }

    function update(clients) {
        let now = Date.now(), next = {}, owners = {}, changed = false;
        let move = settings(["windowsMove", "windows", "global"]);
        // Hyprland uses fadeIn for WINDOW_ALPHA_FULLSCREEN in both directions.
        let fade = settings(["fadeIn", "fade", "global"]);
        for (let client of clients)
            if (client?.mapped && !client.hidden && client.fullscreen > 0)
                owners[client.workspace?.id] = client.address;
        for (let client of clients) {
            if (!client?.mapped || client.hidden || !client.address || !client.at || !client.size)
                continue;
            let address = client.address, previous = windows[address];
            let target = Qt.rect(client.at[0], client.at[1], client.size[0], client.size[1]);
            let mode = Number(client.fullscreen) || 0;
            let owner = owners[client.workspace?.id];
            let targetAlpha = !owner || owner === address || client.pinned || client.allowedOverFullscreen ? 1 : 0;
            let samePlace = previous && previous.workspace === client.workspace?.id && previous.monitor === client.monitor;
            let geometryChanged = previous && (previous.to.x !== target.x || previous.to.y !== target.y
                || previous.to.width !== target.width || previous.to.height !== target.height);
            let modeChanged = previous && previous.mode !== mode;
            let alphaChanged = previous && previous.alphaTo !== targetAlpha;
            if (previous && samePlace && !geometryChanged && !modeChanged && !alphaChanged) {
                next[address] = previous;
                continue;
            }
            let start = now - fullscreenEvent >= 0 && now - fullscreenEvent < 100 ? fullscreenEvent : now;
            let animate = samePlace && geometryChanged && (modeChanged || resizing(address));
            next[address] = {
                workspace: client.workspace?.id, monitor: client.monitor, mode: mode,
                from: animate ? rectangle(address, target, start) : target, to: target,
                start: start, duration: animate ? duration(move) : 0,
                curve: configuration.curves[move.bezier] || [0, 0.75, 0.15, 1],
                alphaFrom: alphaChanged && samePlace ? alpha(address, start) : targetAlpha,
                alphaTo: targetAlpha, alphaStart: start,
                alphaDuration: alphaChanged && samePlace ? duration(fade) : 0,
                alphaCurve: configuration.curves[fade.bezier] || [0, 0.75, 0.15, 1]
            };
            // A geometry update must not restart an existing visibility fade.
            if (previous && samePlace && !alphaChanged) {
                for (let key of ["alphaFrom", "alphaStart", "alphaDuration", "alphaCurve"])
                    next[address][key] = previous[key];
            }
            changed = true;
        }
        if (changed || Object.keys(next).length !== Object.keys(windows).length) {
            frameTime = now;
            windows = next;
            motion.changed();
        }
    }

    onActiveChanged: frameTime = Date.now()
    property Timer clock: Timer {
        interval: 16
        repeat: true
        running: motion.active && motion.moving
        onTriggered: {
            motion.frameTime = Date.now();
            if (!motion.moving)
                motion.changed();
        }
    }
}
