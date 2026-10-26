import QtQuick
import Quickshell.Io
import Quickshell.Hyprland

// Toplevel exports contain window pixels, without the compositor's workspace transform.
QtObject {
    id: motion

    property bool active: false
    property bool supported: false
    property size screenSize: Qt.size(0, 0)
    property string monitorName: ""
    property int workspaceId: 0
    property int specialWorkspaceId: 0
    property int previousWorkspace: 0
    property int previousSpecial: 0
    property bool initialized: false
    property bool animationsEnabled: false
    property bool wraparound: false
    property real workspaceGap: 0
    property var animationNodes: ({})
    property var curves: ({})
    property var transitions: ({})
    property double frameTime: Date.now()
    readonly property bool moving: Object.keys(transitions).length > 0
    signal changed()

    function refreshConfig() {
        if (supported && !configProbe.running)
            configProbe.running = true;
    }

    function settings(special, incoming) {
        let parent = special ? "specialWorkspace" : "workspaces";
        for (let name of [parent + (incoming ? "In" : "Out"), parent, "global"]) {
            let node = animationNodes[name];
            if (node?.overridden)
                return node;
        }
        return {enabled: false, speed: 0, style: "", bezier: ""};
    }

    function cubic(t, a, b) {
        return 3 * (1 - t) * (1 - t) * t * a + 3 * (1 - t) * t * t * b + t * t * t;
    }

    function ease(progress, curve) {
        if (progress <= 0 || progress >= 1)
            return progress;
        let low = 0, high = 1;
        for (let i = 0; i < 15; ++i) {
            let t = (low + high) / 2;
            if (cubic(t, curve[0], curve[2]) < progress) low = t;
            else high = t;
        }
        return cubic((low + high) / 2, curve[1], curve[3]);
    }

    function transform(id, at) {
        let entry = transitions[id];
        if (!entry)
            return {x: 0, y: 0, alpha: 1};
        let progress = Math.max(0, Math.min(1, ((at ?? frameTime) - entry.start) / entry.duration));
        let eased = ease(progress, entry.curve);
        return {x: entry.from.x + (entry.to.x - entry.from.x) * eased,
                y: entry.from.y + (entry.to.y - entry.from.y) * eased,
                alpha: Math.max(0, Math.min(1, entry.from.alpha + (entry.to.alpha - entry.from.alpha) * eased))};
    }

    function includes(id) {
        return id === workspaceId || id === specialWorkspaceId || transitions[id] !== undefined;
    }

    function exiting(id) { return transitions[id]?.exiting ?? false; }

    function endpoint(config, incoming, left, special) {
        let style = config.style || "slide";
        let args = style.split(/\s+/);
        let vertical = style.startsWith("slidevert") || style.startsWith("slidefadevert");
        if (["top", "bottom", "left", "right"].indexOf(args[1]) >= 0) {
            vertical = args[1] === "top" || args[1] === "bottom";
            left = args[1] === "bottom" || args[1] === "right";
        }
        let percentage = args[args.length - 1].endsWith("%") ? parseFloat(args[args.length - 1]) / 100 : 1;
        if (!isFinite(percentage)) percentage = 1;
        let distance = ((vertical ? screenSize.height : screenSize.width)
                        + (style.startsWith("slidefade") ? 0 : workspaceGap)) * percentage;
        let sign = incoming ? (left ? 1 : -1) : (left ? -1 : 1);
        return {x: style === "fade" || vertical ? 0 : sign * distance,
                y: style === "fade" || !vertical ? 0 : sign * distance,
                alpha: special || style === "fade" || style.startsWith("slidefade") ? 0 : 1};
    }

    function change(oldId, newId, special) {
        if (!initialized || !oldId && !newId)
            return;
        let now = Date.now(), next = Object.assign({}, transitions);
        let left = newId > oldId;
        if (wraparound && !special && oldId > 0 && newId > 0) {
            let ids = Hyprland.workspaces.values.map(w => w.id).filter(id => id > 0);
            if (Math.min(oldId, newId) === Math.min(...ids) && Math.max(oldId, newId) === Math.max(...ids))
                left = !left;
        }
        for (let incoming of [false, true]) {
            let id = incoming ? newId : oldId;
            if (!id) continue;
            let config = settings(special, incoming);
            let duration = animationsEnabled && config.enabled ? Number(config.speed) * 100 : 0;
            if (!isFinite(duration) || duration <= 0 || !special && (!oldId || !newId)) {
                delete next[id];
                continue;
            }
            let offscreen = endpoint(config, incoming, special ? incoming : left, special);
            let from = transitions[id] ? transform(id, now) : incoming ? offscreen : {x: 0, y: 0, alpha: 1};
            next[id] = {from: from, to: incoming ? {x: 0, y: 0, alpha: 1} : offscreen,
                        start: now, duration: duration, exiting: !incoming,
                        curve: curves[config.bezier] || [0, 0.75, 0.15, 1]};
        }
        frameTime = now;
        transitions = next;
        changed();
    }

    onWorkspaceIdChanged: {
        let old = previousWorkspace;
        previousWorkspace = workspaceId;
        change(old, workspaceId, false);
    }
    onSpecialWorkspaceIdChanged: {
        let old = previousSpecial;
        previousSpecial = specialWorkspaceId;
        change(old, specialWorkspaceId, true);
    }
    onActiveChanged: {
        if (initialized && active) {
            advance();
            refreshConfig();
        }
    }
    onMonitorNameChanged: Qt.callLater(resetMonitor)
    function resetMonitor() {
        transitions = ({});
        previousWorkspace = workspaceId;
        previousSpecial = specialWorkspaceId;
    }
    function advance() {
        let now = Date.now(), next = {}, completed = false;
        frameTime = now;
        for (let id in transitions) {
            let entry = transitions[id];
            if (now < entry.start + entry.duration) next[id] = entry;
            else completed = true;
        }
        if (completed) {
            transitions = next;
            changed();
        }
    }
    Component.onCompleted: {
        previousWorkspace = workspaceId;
        previousSpecial = specialWorkspaceId;
        initialized = true;
        refreshConfig();
    }

    property Timer clock: Timer {
        interval: 16
        repeat: true
        running: motion.active && motion.moving
        onTriggered: motion.advance()
    }
    property Connections events: Connections {
        target: Hyprland
        function onRawEvent(event) { if (event.name === "configreloaded") motion.refreshConfig(); }
    }
    property Process configProbe: Process {
        command: ["hyprctl", "-j", "--batch", "animations; getoption animations:enabled; getoption general:gaps_workspaces; getoption animations:workspace_wraparound"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    let data = text.trim().split(/\n\s*\n/).map(value => JSON.parse(value));
                    let nodes = {}, curves = {};
                    for (let node of data[0][0]) nodes[node.name] = node;
                    for (let curve of data[0][1]) {
                        let points = [curve.X0, curve.Y0, curve.X1, curve.Y1];
                        if (points.every(value => typeof value === "number" && isFinite(value)))
                            curves[curve.name] = points;
                    }
                    motion.animationNodes = nodes;
                    motion.curves = curves;
                    motion.animationsEnabled = data[1].bool === true || data[1].int === 1;
                    motion.workspaceGap = Number(data[2].int) || 0;
                    motion.wraparound = data[3].bool === true || data[3].int === 1;
                } catch (error) { console.warn("AppleSearch workspace animation settings: " + error); }
            }
        }
    }
}
