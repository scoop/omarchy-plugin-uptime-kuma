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

    implicitWidth: showing ? row.implicitWidth : 0
    implicitHeight: showing ? barSize : 0
    visible: showing

    onWantsAttentionChanged: {
        if (!wantsAttention) {
            graceTimer.stop();
            armed = false;
        } else if (!armed) {
            graceTimer.restart();
        }
    }

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
    }

    onSettingsChanged: pushSettings()
    onServiceChanged: pushSettings()
    Component.onCompleted: pushSettings()

    Row {
        id: row
        anchors.centerIn: parent
        spacing: Style.spacing.xs

        Text {
            anchors.verticalCenter: parent.verticalCenter
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
            anchors.verticalCenter: parent.verticalCenter
            visible: root.downCount > 0
            text: String(root.downCount)
            font.family: bar ? bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
            color: Color.urgent
            textFormat: Text.PlainText
        }
    }

    MouseArea {
        anchors.fill: parent
        enabled: root.showing
        onClicked: if (bar && bar.shell) bar.shell.toggle("scoop.uptime-kuma", "{}")
    }
}
