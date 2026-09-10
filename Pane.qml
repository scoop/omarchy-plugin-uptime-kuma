import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "src/rows.js" as Rows

// The operator view: summoned deliberately, read quickly, dismissed.
//
// Problems come first, flattened out of the hierarchy — when something is
// broken you want to see what, not to go looking for it. Everything else stays
// folded into its group until asked for.
Item {
    id: root

    property string omarchyPath: ""
    property var shell: null
    property var manifest: null
    // Injected by the host for plugins that pair a UI with a service entry.
    property var service: null

    property bool opened: false
    property string filterText: ""
    property int selectedIndex: 0
    property var collapsed: ({})
    property var expandedId: 0

    readonly property var view: service && service.view ? service.view : null
    readonly property string connection: service ? service.connection : "setup"

    // The flattened list the keyboard actually moves through.
    readonly property var rows: Rows.flatten(view, filterText, collapsed)

    property color background: Color.menu.background
    property color foreground: Color.menu.text
    property var borderSpec: Border.surfaceSpec(
        "menu",
        "border",
        Color.menu.border,
        Math.max(1, Style.space(2))
    )

    function open() {
        opened = true;
        selectedIndex = 0;
        Qt.callLater(function () {
            keyCatcher.forceActiveFocus();
        });
    }

    function close() {
        opened = false;
        filterText = "";
        expandedId = 0;
    }

    function toggle() {
        opened ? close() : open();
    }

    // The theme gives us three roles and no palette of named colours, which
    // suits a three-state vocabulary: alarm, attention, and calm. A healthy
    // monitor is deliberately the quietest thing on screen.
    function statusColor(status) {
        if (status === "down") {
            return Color.urgent;
        }
        if (status === "degraded") {
            return Color.accent;
        }
        return Color.muted;
    }

    function select(delta) {
        if (rows.length === 0) {
            return;
        }
        var next = selectedIndex + delta;
        selectedIndex = Math.max(0, Math.min(rows.length - 1, next));
        list.positionViewAtIndex(selectedIndex, ListView.Contain);
    }

    function activate() {
        var row = rows[selectedIndex];
        if (!row) {
            return;
        }
        if (row.type === "group") {
            var next = {};
            for (var key in collapsed) {
                next[key] = collapsed[key];
            }
            next[row.id] = !next[row.id];
            collapsed = next;
            return;
        }
        // A monitor row opens where the operator can actually do something.
        Quickshell.execDetached([
            "xdg-open",
            (service ? service.baseUrl.replace(/\/$/, "") : "") + "/dashboard/" + row.id,
        ]);
        close();
    }

    function expandSelected() {
        var row = rows[selectedIndex];
        if (row && row.type === "monitor") {
            expandedId = expandedId === row.id ? 0 : row.id;
        }
    }

    IpcHandler {
        target: "scoop.uptime-kuma"

        function open(): void {
            root.open();
        }
        function close(): void {
            root.close();
        }
        function show(): void {
            root.open();
        }
        function hide(): void {
            root.close();
        }
        function toggle(): void {
            root.toggle();
        }
    }

    PanelWindow {
        id: panel
        visible: root.opened
        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }
        color: "transparent"
        WlrLayershell.namespace: "scoop-uptime-kuma"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
        exclusionMode: ExclusionMode.Ignore

        Rectangle {
            anchors.fill: parent
            color: Color.menu.scrim
        }

        MouseArea {
            anchors.fill: parent
            onClicked: root.close()
        }

        BorderSurface {
            id: card
            width: Math.min(Style.space(760), panel.width - Style.gapsOut * 2)
            height: Math.min(Style.space(620), panel.height - Style.gapsOut * 2)
            radius: Style.space(12)
            anchors.centerIn: parent
            color: root.background
            borderSpec: root.borderSpec
            padding: Style.spacing.panelPadding

            MouseArea {
                anchors.fill: parent
                onClicked: {}
            }

            Item {
                id: keyCatcher
                anchors.fill: parent
                focus: true

                Keys.priority: Keys.BeforeItem
                Keys.onPressed: function (event) {
                    if (event.key === Qt.Key_Escape) {
                        if (root.filterText) {
                            root.filterText = "";
                            root.selectedIndex = 0;
                        } else {
                            root.close();
                        }
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Down) {
                        root.select(1);
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Up) {
                        root.select(-1);
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        root.activate();
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Space) {
                        root.expandSelected();
                        event.accepted = true;
                    } else if (Util.editsFilter(event, root.filterText)) {
                        root.filterText = Util.editedFilter(event, root.filterText);
                        root.selectedIndex = 0;
                        event.accepted = true;
                    } else if (
                        event.text &&
                        event.text.length === 1 &&
                        event.text.charCodeAt(0) >= 32 &&
                        event.text.charCodeAt(0) !== 127
                    ) {
                        root.filterText = root.filterText + event.text;
                        root.selectedIndex = 0;
                        event.accepted = true;
                    }
                }

                Column {
                    anchors.fill: parent
                    spacing: Style.spacing.md

                    // ------------------------------------------------ summary
                    Row {
                        width: parent.width
                        spacing: Style.spacing.sm

                        Text {
                            text: {
                                if (root.connection === "setup") {
                                    return "Not configured";
                                }
                                if (!root.view) {
                                    return "Connecting…";
                                }
                                var c = root.view.counts;
                                return (
                                    c.up +
                                    " up · " +
                                    c.down +
                                    " down · " +
                                    c.degraded +
                                    " degraded · " +
                                    c.paused +
                                    " paused"
                                );
                            }
                            color: root.foreground
                            font.pixelSize: Style.font.title
                            font.family: Style.font.family
                            textFormat: Text.PlainText
                        }
                    }

                    // Stale data must announce itself. A healthy-looking pane
                    // that is simply out of date is the one lie this must not
                    // tell.
                    Rectangle {
                        width: parent.width
                        height: visible ? staleText.implicitHeight + Style.spacing.sm * 2 : 0
                        visible: root.connection === "unreachable"
                        color: Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.15)
                        radius: Style.space(6)

                        Text {
                            id: staleText
                            anchors.centerIn: parent
                            text: "Can't reach Uptime Kuma — showing the last known state."
                            color: root.foreground
                            font.pixelSize: Style.font.caption
                            textFormat: Text.PlainText
                        }
                    }

                    Text {
                        visible: root.filterText !== ""
                        text: "filter: " + root.filterText
                        color: Color.muted
                        font.pixelSize: Style.font.caption
                        textFormat: Text.PlainText
                    }

                    // -------------------------------------------------- rows
                    ListView {
                        id: list
                        width: parent.width
                        height: parent.height - y
                        clip: true
                        model: root.rows
                        currentIndex: root.selectedIndex

                        delegate: Rectangle {
                            required property var modelData
                            required property int index

                            width: list.width
                            height: rowColumn.implicitHeight + Style.spacing.sm
                            color: index === root.selectedIndex ? Color.menu.selectedBackground : "transparent"
                            radius: Style.space(4)

                            Column {
                                id: rowColumn
                                width: parent.width - Style.spacing.sm * 2
                                x: Style.spacing.sm
                                y: Style.spacing.sm / 2
                                spacing: Style.space(2)

                                Row {
                                    spacing: Style.spacing.sm

                                    Rectangle {
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: Style.space(8)
                                        height: Style.space(8)
                                        radius: width / 2
                                        color: root.statusColor(modelData.status)
                                    }

                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: modelData.label
                                        color:
                                            index === root.selectedIndex
                                                ? Color.menu.selectedText
                                                : root.foreground
                                        font.pixelSize: Style.font.body
                                        font.bold: modelData.type !== "monitor"
                                        textFormat: Text.PlainText
                                    }

                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: modelData.detail
                                        color: Color.muted
                                        font.pixelSize: Style.font.caption
                                        textFormat: Text.PlainText
                                    }
                                }

                                // The error text: the whole reason this plugin
                                // uses the socket interface at all.
                                Text {
                                    visible: modelData.error !== "" && modelData.status === "down"
                                    width: rowColumn.width
                                    text: modelData.error
                                    color: Color.urgent
                                    font.pixelSize: Style.font.caption
                                    wrapMode: Text.WordWrap
                                    maximumLineCount: root.expandedId === modelData.id ? 6 : 1
                                    elide: Text.ElideRight
                                    textFormat: Text.PlainText
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
