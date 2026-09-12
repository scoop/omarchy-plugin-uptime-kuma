import QtQuick
import qs.Commons
import qs.Ui

// The bar presence: absent while everything is healthy.
//
// This is the whole point of the widget. A monitoring indicator that is always
// there is wallpaper — you stop seeing it. One that appears only when it has
// something to say is worth looking at when it does.
BarWidget {
    id: root

    // The host injects settings into bar widgets but not into services, so the
    // widget is where configuration enters and gets pushed down.
    property var service: bar && bar.shell ? bar.shell.serviceFor("scoop.uptime-kuma") : null

    readonly property int downCount: service && service.view ? service.view.counts.down : 0
    readonly property string connection: service ? service.connection : "setup"

    // Slow to alarm, instant to calm: a monitor that fails one check and
    // recovers should not make the bar flicker, but a recovery should clear
    // the indicator at once.
    property bool armed: false

    readonly property bool wantsAttention: downCount > 0 || connection === "unreachable"
    readonly property bool showing: armed && wantsAttention

    // The bar's widget list has zero spacing, so every widget pads itself —
    // WidgetButton keeps a horizontal margin, the icon widgets sit in a fixed
    // slot wider than their glyph. Without that the indicator butts straight
    // against whatever plugin is next to it.
    //
    // Which edge that padding belongs on depends on the bar: a horizontal bar
    // lays its widgets out in a Row, a vertical one in a Column, so the gap
    // that separates us from a neighbour runs along the other axis and the
    // remaining one is simply the bar's own thickness. 14 puts a lone glyph in
    // a slot the size of the icon widgets beside it.
    readonly property int slotPadding: Style.space(14)

    implicitWidth: showing ? (vertical ? barSize : content.implicitWidth + slotPadding) : 0
    implicitHeight: showing ? (vertical ? content.implicitHeight + slotPadding : barSize) : 0
    visible: showing

    // Evaluated on change AND at startup: a property-change handler alone never
    // fires when the value is already true the moment the widget is created,
    // which is exactly what happens when the bar rebuilds its widgets while a
    // monitor is already down. The Indicator then stayed hidden forever.
    function evaluateAttention() {
        if (!wantsAttention) {
            graceTimer.stop();
            armed = false;
        } else if (!armed && !graceTimer.running) {
            graceTimer.restart();
        }
    }

    onWantsAttentionChanged: evaluateAttention()

    Timer {
        id: graceTimer
        interval: 30000
        repeat: false
        onTriggered: if (root.wantsAttention) root.armed = true
    }

    function pushSettings() {
        if (!service) {
            return;
        }
        service.baseUrl = setting("baseUrl", "");
        service.username = setting("username", "");
        service.allowPlaintext = setting("allowPlaintext", false) === true;
    }

    onSettingsChanged: pushSettings()
    onServiceChanged: {
        pushSettings();
        evaluateAttention();
    }
    Component.onCompleted: {
        pushSettings();
        evaluateAttention();
    }

    // The bar widget exposes no IPC at all.
    //
    // A `probe` method used to answer here with the down count, the connection
    // state and whether a base URL was configured. It changed nothing, which is
    // why it felt harmless, but it read out state derived from a remote server
    // to any process that could reach `omarchy-shell` — with nobody present to
    // agree to that. The widget's only job is to be looked at, so there is
    // nothing here to keep.

    // A Grid rather than a Row: on a vertical bar the glyph and its count have
    // to stack, because side by side they would run out past the bar's edge as
    // soon as more than one monitor is down. Positioners manage their children's
    // position on the axes they lay out along, so the centering that a Row let
    // the children anchor for themselves is the Grid's own alignment here.
    Grid {
        id: content
        anchors.centerIn: parent
        columns: root.vertical ? 1 : 2
        spacing: Style.spacing.xs
        horizontalItemAlignment: Grid.AlignHCenter
        verticalItemAlignment: Grid.AlignVCenter

        Text {
            // Unreachable is not the same alarm as a monitor being down, and
            // must never be mistaken for it: we are not saying something broke,
            // we are saying we no longer know.
            text: root.connection === "unreachable" ? "\uf127" : "\uf0f3"
            font.family: bar ? bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
            color: root.connection === "unreachable" ? Color.muted : Color.urgent
            textFormat: Text.PlainText
        }

        Text {
            visible: root.downCount > 0
            text: String(root.downCount)
            font.family: bar ? bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
            // While we cannot reach Uptime Kuma this count is the last thing we
            // were told, not what is true now. It should not look as certain as
            // the glyph beside it admits we are not.
            color: root.connection === "unreachable" ? Color.muted : Color.urgent
            textFormat: Text.PlainText
        }
    }

    MouseArea {
        anchors.fill: parent
        enabled: root.showing
        onClicked: if (bar && bar.shell) bar.shell.toggle("scoop.uptime-kuma", "{}")
    }
}
