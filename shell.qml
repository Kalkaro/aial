// Qt otherwise advances animations by the primary screen's frame interval,
// which runs them too fast and unevenly on a higher refresh rate monitor.
//@ pragma Env QSG_USE_SIMPLE_ANIMATION_DRIVER=1
// Qt's default subpixel text antialiasing leaves colour fringes on the text.
//@ pragma Env QSG_DISTANCEFIELD_ANTIALIASING=gray
import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland

ShellRoot {
    id: root

    Theme { id: theme }
    FontLoader { id: uiFont; source: "fonts/Geist.ttf" }

    property bool opened: Quickshell.env("APPLESEARCH_HIDDEN") !== "1"
    property bool backendReady: false
    property string phase: "loading"
    property string statusMessage: "Preparing local search…"
    property var results: []
    property int requestId: 0
    property int selected: 0
    property bool selectionExplicit: false
    property var hoverPosition: null
    property bool dragging: false
    property bool searching: false
    property bool semantic: false
    property int resultsHeight: 0
    property double queryStartedMs: 0
    property double firstResultMs: -1
    property var targetScreen: Quickshell.screens[0]
    readonly property string namespace: Quickshell.env("APPLESEARCH_NAMESPACE") || "applesearch"
    readonly property string directory: Quickshell.env("APPLESEARCH_SOURCE_DIR") || decodeURIComponent(Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "").replace(/\/$/, ""))
    readonly property bool hasQuery: input.text.trim().length > 0
    readonly property bool isHyprland: Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE").length > 0
    // Result names stay dimmer until selected, then move toward white (black on light palettes).
    readonly property color titleColor: Qt.alpha(theme.base05, 0.8)
    readonly property color selectedTitleColor: Qt.tint(theme.base05, theme.dark ? "#80ffffff" : "#80000000")
    onOpenedChanged: {
        hoverPosition = null;
        if (backendReady)
            backend.write(JSON.stringify({action: "active", value: opened}) + "\n");
    }

    function showPanel() {
        theme.refresh();
        if (panel.visible) {
            // Reopening during the close fade reverses it and keeps the query.
            requestSearch();
        } else {
            targetScreen = Quickshell.screens.find(s => s.name === Hyprland.focusedMonitor?.name) || Quickshell.screens[0];
            input.text = "";
            results = [];
            selected = 0;
            selectionExplicit = false;
            presence.value = 0;
        }
        panel.fade = 1;
        opened = true;
        focusTimer.restart();
    }

    function hidePanel() {
        // Focus returns immediately; the card fades out with its content.
        opened = false;
        panel.fade = 0;
        grab.active = false;
        focusTimer.stop();
        debounce.stop();
        // Results still in flight must not resize the closing card.
        ++requestId;
    }

    // Runs once the close animation has hidden the window.
    function resetPanel() {
        input.text = "";
        results = [];
        ++requestId;
        if (backendReady)
            backend.write(JSON.stringify({action: "search", id: requestId, query: ""}) + "\n");
    }

    function requestSearch() {
        if (backendReady)
            backend.write(JSON.stringify({action: "search", id: requestId, query: input.text}) + "\n");
    }

    function updateResultsHeight() {
        if (!hasQuery)
            resultsHeight = 0;
        else if (results.length)
            resultsHeight = results.length * 62 + (phase === "error" ? 43 : 16);
        else if (!searching && (backendReady && phase !== "loading" || phase === "error"))
            resultsHeight = 62;
        // Keep the current height while the next query's results are pending.
    }

    function activate(reveal) {
        if (results.length && selected >= 0 && selected < results.length)
            backend.write(JSON.stringify({action: "open", id: results[selected].id, reveal: reveal}) + "\n");
    }

    function fileUrl(path) {
        return "file://" + encodeURI(path).replace(/#/g, "%23").replace(/\?/g, "%3F");
    }

    function iconUrl(result) {
        let fallback = result.kind === "app" ? "application-x-executable" : "text-x-generic";
        let icon = result.icon || fallback;
        return icon.startsWith("/") ? fileUrl(icon) : Quickshell.iconPath(icon, fallback);
    }

    function dragResult(result) {
        dragSource.result = result;
        // QDrag::exec() blocks in a nested event loop. Starting it outside the
        // row's event handling lets results be rebuilt while a drag is running.
        Qt.callLater(() => dragSource.Drag.active = true);
    }

    function selectResult(index) {
        selected = index;
        selectionExplicit = true;
    }

    function hoverResult(index, position) {
        // Delegates also receive hover events when results appear or reorder.
        // Only actual movement in window coordinates should change selection.
        let previous = hoverPosition;
        hoverPosition = position;
        if (previous && (previous.x !== position.x || previous.y !== position.y))
            selectResult(index);
    }

    function receive(message) {
        if (message.type === "ready") {
            backendReady = true;
            backend.write(JSON.stringify({action: "active", value: opened}) + "\n");
            if (hasQuery)
                requestSearch();
        } else if (message.type === "status") {
            phase = message.phase;
            statusMessage = message.message;
            if (phase === "error") {
                searching = false;
            }
            updateResultsHeight();
        } else if (message.type === "results" && message.id === requestId) {
            // A slower lexical response must never replace semantic results.
            if (semantic && !message.semantic)
                return;
            // Empty keyword results are provisional while semantic search runs.
            // Keep the displayed rows until this query has results or finishes.
            if (message.results.length > 0 || !message.searching) {
                let previous = selectionExplicit && selected >= 0 && selected < results.length ? results[selected].id : "";
                results = message.results;
                if (results.length > 0 && firstResultMs < 0)
                    firstResultMs = Date.now() - queryStartedMs;
                let same = results.findIndex(r => r.id === previous);
                selected = Math.max(0, same);
                selectionExplicit = same >= 0;
            }
            semantic = message.semantic;
            searching = message.searching;
            updateResultsHeight();
        } else if (message.type === "index" && hasQuery) {
            requestSearch();
        } else if (message.type === "opened") {
            hidePanel();
        } else if (message.type === "error") {
            statusMessage = message.message;
            searching = false;
            updateResultsHeight();
        }
    }

    Component.onCompleted: {
        targetScreen = Quickshell.screens.find(s => s.name === Hyprland.focusedMonitor?.name) || Quickshell.screens[0];
        if (opened) {
            presence.value = 0;
            focusTimer.start();
        }
    }

    IpcHandler {
        target: "spotlight"
        function toggle(): void { if (root.opened) root.hidePanel(); else root.showPanel(); }
        function present(): void { root.showPanel(); }
        function hide(): void { root.hidePanel(); }
        function quit(): void { Qt.quit(); }
        function processId(): int { return Quickshell.processId; }
        function search(query: string): void {
            if (!root.opened)
                root.showPanel();
            input.text = query;
        }
        function state(): string {
            return JSON.stringify({visible: root.opened, query: input.text, results: root.results,
                                   selected: root.selected,
                                   phase: root.phase, semantic: root.semantic, searching: root.searching,
                                   height: card.height + 36, surfaceHeight: panel.height,
                                   ready: root.backendReady, message: root.statusMessage,
                                   screen: panel.screen.name, firstResultMs: root.firstResultMs,
                                   namespace: root.namespace,
                                   font: {family: uiFont.name, ready: uiFont.status === FontLoader.Ready},
                                   theme: {source: theme.path, base00: theme.base00.toString(),
                                           base05: theme.base05.toString(), accent: theme.base0D.toString(), dark: theme.dark}});
        }
    }

    Process {
        id: backend
        command: [root.directory + "/launch.sh", "--backend"]
        running: true
        stdinEnabled: true
        stdout: SplitParser {
            onRead: data => {
                try { root.receive(JSON.parse(data)); }
                catch (error) { console.warn("AppleSearch: " + error); }
            }
        }
        stderr: SplitParser { onRead: data => console.log("AppleSearch: " + data) }
        onExited: (exitCode, exitStatus) => {
            root.backendReady = false;
            root.phase = "error";
            root.searching = false;
            root.updateResultsHeight();
            root.statusMessage = "Local search stopped · see Quickshell logs";
        }
    }

    Timer { id: debounce; interval: 25; onTriggered: root.requestSearch() }
    // Nix may replace a palette symlink without changing the watched target.
    Timer { interval: 2000; repeat: true; running: root.opened; onTriggered: theme.refresh() }
    Timer {
        id: focusTimer
        interval: 30
        onTriggered: {
            input.forceActiveFocus();
            if (root.isHyprland)
                grab.active = true;
        }
    }

    PanelWindow {
        id: panel
        screen: root.targetScreen
        // Stays mapped until the close fade ends, and until a drag started
        // from it ends, so the drag is not cancelled.
        visible: root.opened || fade > 0 || root.dragging
        onVisibleChanged: if (!visible) root.resetPanel()
        // Closing fades the card out in place; reopening fades it back in.
        property real fade: root.opened ? 1 : 0
        Behavior on fade {
            // A fresh open sets it while hidden, leaving that fade to the pop.
            enabled: panel.visible
            NumberAnimation { duration: 120; easing.type: Easing.OutQuad }
        }
        color: "transparent"
        anchors.top: true
        margins.top: Math.min(Math.round(screen.height * 0.22), Math.max(0, screen.height - implicitHeight))
        implicitWidth: Math.min(680, screen.width - 48)
        // Keep the Wayland surface stable; only the card inside it animates.
        implicitHeight: Math.min(72 + 7 * 62 + 43 + 36, screen.height)
        // Clicks pass through as soon as the panel starts closing.
        mask: Region { item: root.opened ? card : null; radius: card.radius }
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.namespace: root.namespace
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

        HyprlandFocusGrab {
            id: grab
            windows: [panel]
            onCleared: if (root.opened) root.hidePanel()
        }

        // A new result count redirects the motion without restarting it.
        Spring {
            id: expansion
            target: Math.min(72 + root.resultsHeight, panel.implicitHeight - 36)
            enabled: panel.visible
        }

        // Opening pops the card in from its search row.
        Spring {
            id: presence
            target: 1
            response: 0.32
            damping: 0.72
            precision: 0.002
            enabled: panel.visible
        }
        // The selection highlight glides to the selected row.
        Spring {
            id: selection
            target: root.selected * 62
            response: 0.1
            enabled: panel.visible
        }

        Scale {
            id: presenceScale
            origin.x: card.width / 2
            origin.y: searchRow.height / 2
            xScale: 0.9 + 0.1 * presence.value
            yScale: xScale
        }

        // Hands a dragged result's file to other apps. Copy only, so a file
        // manager never moves the original out of place.
        Item {
            id: dragSource
            property var result: null
            Drag.dragType: Drag.Automatic
            Drag.supportedActions: Qt.CopyAction
            Drag.proposedAction: Qt.CopyAction
            Drag.mimeData: result ? {"text/uri-list": [root.fileUrl(result.id)], "text/plain": result.id} : ({})
            Drag.imageSource: result ? root.iconUrl(result) : ""
            Drag.imageSourceSize: Qt.size(48, 48)
            Drag.hotSpot: Qt.point(24, 24)
            // The panel closes as the drag begins, getting out of the way of drop targets.
            Drag.onDragStarted: {
                root.dragging = true;
                root.hidePanel();
            }
            Drag.onDragFinished: root.dragging = false
        }

        Rectangle {
            id: card
            x: 16
            y: 12
            width: parent.width - 32
            height: expansion.value
            radius: 22
            color: Qt.alpha(theme.base00, 0.8)
            opacity: Math.min(1, presence.value * 2) * panel.fade
            transform: presenceScale
            clip: true

            Item {
                id: searchRow
                width: parent.width
                height: 72

                Item {
                    x: 24
                    anchors.verticalCenter: parent.verticalCenter
                    width: 23
                    height: 23
                    opacity: 0.65
                    Rectangle {
                        width: 15; height: 15; radius: 8
                        color: "transparent"
                        border.width: 1.7; border.color: theme.base05
                        x: 1; y: 1
                    }
                    Rectangle {
                        width: 9; height: 1.7; radius: 1
                        color: theme.base05; rotation: 45
                        x: 13; y: 17
                    }
                }

                TextField {
                    id: input
                    x: 62
                    width: parent.width - x - 24
                    height: parent.height
                    padding: 0
                    font.family: uiFont.name
                    font.pixelSize: 24
                    font.weight: Font.Normal
                    color: theme.base05
                    placeholderText: "Search anything"
                    placeholderTextColor: Qt.alpha(theme.base05, 0.65)
                    selectionColor: theme.base0D
                    selectedTextColor: theme.base00
                    background: Item {}
                    focus: true
                    selectByMouse: true
                    Accessible.name: "Search applications and files"
                    onTextChanged: {
                        root.queryStartedMs = Date.now();
                        root.firstResultMs = -1;
                        ++root.requestId;
                        root.semantic = false;
                        root.searching = root.hasQuery;
                        root.selected = 0;
                        root.selectionExplicit = false;
                        root.hoverPosition = null;
                        if (!root.hasQuery) {
                            root.results = [];
                        }
                        root.updateResultsHeight();
                        debounce.restart();
                    }
                    Keys.onEscapePressed: root.hidePanel()
                    Keys.onDownPressed: event => {
                        if (root.results.length)
                            root.selectResult((root.selected + 1) % root.results.length);
                        event.accepted = true;
                    }
                    Keys.onUpPressed: event => {
                        if (root.results.length)
                            root.selectResult((root.selected + root.results.length - 1) % root.results.length);
                        event.accepted = true;
                    }
                    Keys.onReturnPressed: event => root.activate((event.modifiers & Qt.ControlModifier) !== 0)
                    Keys.onEnterPressed: event => root.activate((event.modifiers & Qt.ControlModifier) !== 0)
                    Keys.onPressed: event => {
                        if (event.key === Qt.Key_R && (event.modifiers & Qt.ControlModifier)) {
                            if (root.backendReady)
                                backend.write(JSON.stringify({action: "refresh"}) + "\n");
                            event.accepted = true;
                        }
                    }
                }

            }

            Rectangle {
                x: 20; y: 72
                width: parent.width - 40; height: 1
                color: Qt.alpha(theme.base05, 0.09)
                visible: root.hasQuery
            }

            Item {
                x: 8
                y: 80
                width: parent.width - 16
                // Keep rows inside the rounded corners while the card grows.
                height: Math.max(0, card.height - y - 8)
                clip: true
                visible: root.hasQuery && root.results.length > 0

                // One highlight moves between the rows, drawn beneath them.
                Rectangle {
                    y: selection.value
                    width: parent.width
                    height: 62
                    radius: 10
                    color: Qt.alpha(theme.base02, 0.26)
                }

                Repeater {
                    model: root.results
                    delegate: Item {
                        id: resultRow
                        required property var modelData
                        required property int index
                        // 1 under the highlight, 0 a row away, so the name brightens as it arrives.
                        readonly property real lit: Math.max(0, 1 - Math.abs(selection.value - y) / height)
                        y: index * 62
                        width: card.width - 16
                        height: 62

                        Image {
                            id: resultIcon
                            x: 16; y: 14
                            width: 32; height: 32
                            source: root.iconUrl(resultRow.modelData)
                            sourceSize.width: 32
                            sourceSize.height: 32
                            fillMode: Image.PreserveAspectFit
                            asynchronous: false
                        }

                        Rectangle {
                            x: 20; y: 17
                            width: 23; height: 28; radius: 4
                            color: theme.base01
                            border.color: theme.base03
                            visible: resultIcon.status === Image.Error
                            Text {
                                anchors.centerIn: parent
                                text: resultRow.modelData.kind === "app" ? "⌘" : "≡"
                                font.pixelSize: 15
                                color: theme.base05
                            }
                        }

                        Text {
                            x: 64
                            y: resultRow.modelData.kind === "app" ? (parent.height - height) / 2 : 11
                            width: parent.width - x - 20
                            text: resultRow.modelData.title
                            textFormat: Text.PlainText
                            elide: Text.ElideRight
                            font.family: uiFont.name
                            font.pixelSize: 15
                            font.weight: Font.Medium
                            color: Qt.tint(root.titleColor, Qt.alpha(root.selectedTitleColor, resultRow.lit))
                        }
                        Text {
                            x: 64; y: 34
                            width: parent.width - x - 20
                            visible: resultRow.modelData.kind !== "app"
                            text: resultRow.modelData.subtitle
                            textFormat: Text.PlainText
                            elide: Text.ElideMiddle
                            font.family: uiFont.name
                            font.pixelSize: 11
                            color: theme.base04
                        }
                        Item { id: dragProxy }
                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            // Moving past the drag threshold drags the result out instead of clicking it.
                            drag.target: dragProxy
                            drag.onActiveChanged: if (drag.active) root.dragResult(resultRow.modelData)
                            onPositionChanged: mouse => root.hoverResult(resultRow.index, mapToItem(panel.contentItem, mouse.x, mouse.y))
                            onClicked: mouse => {
                                root.selectResult(resultRow.index);
                                root.activate((mouse.modifiers & Qt.ControlModifier) !== 0);
                            }
                        }
                    }
                }
            }

            Text {
                x: 26; y: 96
                width: parent.width - 52
                visible: root.hasQuery && root.results.length === 0
                         && (root.phase === "error" || root.backendReady && root.phase !== "loading" && !root.searching)
                text: root.phase === "error" ? root.statusMessage : "No results"
                textFormat: Text.PlainText
                elide: Text.ElideRight
                font.family: uiFont.name
                font.pixelSize: 12
                color: theme.base04
            }

            Item {
                x: 25
                y: 88 + root.results.length * 62
                width: parent.width - 50
                height: 22
                visible: root.hasQuery && root.results.length > 0
                         && root.phase === "error"
                Rectangle {
                    width: 4; height: 4; radius: 2
                    anchors.verticalCenter: parent.verticalCenter
                    color: theme.base08
                    opacity: 0.8
                }
                Text {
                    x: 12
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Keyword search · model unavailable"
                    font.family: uiFont.name
                    font.pixelSize: 10
                    color: theme.base04
                }
            }
        }
    }
}
