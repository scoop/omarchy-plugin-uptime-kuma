import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui

// What one Monitor is doing, for the row the operator has selected.
//
// The list above answers "what is broken"; this answers "and how bad is it" —
// whether the Status is a blip or an hour old, whether the last day was clean,
// whether latency has been climbing towards this. Every value shown is
// computed in src/model.js and arrives here already phrased: this file decides
// where things sit and what colour they are, and nothing else.
Item {
    id: root

    // One monitor as `buildView` produces it, or null when the selected row is
    // a Group or a heading and there is nothing to detail.
    property var monitor: null

    // Theming, passed down by whoever mounts this. The defaults stand alone so
    // the component renders correctly on its own.
    property color foreground: Color.menu.text
    property string fontFamily: Style.font.menuFamily
    // The theme's own green, which the shell palette does not carry. Grey is
    // what "we don't know" looks like, so it is only the fallback.
    property color okColor: Color.muted

    readonly property bool present: monitor !== null && monitor !== undefined
    readonly property color dim: Qt.darker(foreground, 1.4)

    visible: present
    implicitHeight: present ? content.implicitHeight : 0

    // The Pane's three colours, so a status reads the same here as it does in
    // the row above.
    function statusColor(status) {
        if (status === "down") {
            return Color.urgent;
        }
        if (status === "degraded") {
            return Color.accent;
        }
        return Qt.rgba(okColor.r, okColor.g, okColor.b, 0.8);
    }

    // One figure and what it is. Absent figures render as nothing at all
    // rather than as a dash: Uptime Kuma not having said is not a measurement.
    component Fact: ColumnLayout {
        id: fact

        property string label: ""
        property string value: ""

        visible: value !== ""
        spacing: Style.spacing.xxs

        PanelSectionHeader {
            text: fact.label
            foreground: root.foreground
            fontFamily: root.fontFamily
        }

        Text {
            text: fact.value
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            textFormat: Text.PlainText
        }
    }

    ColumnLayout {
        id: content
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.spacing.lg

        PanelSeparator {
            Layout.fillWidth: true
            foreground: root.foreground
        }

        // ------------------------------------------------------ what it is doing
        RowLayout {
            Layout.fillWidth: true
            spacing: Style.spacing.lg

            Rectangle {
                Layout.alignment: Qt.AlignVCenter
                width: Style.space(7)
                height: Style.space(7)
                radius: width / 2
                color: root.statusColor(root.present ? root.monitor.status : "up")
            }

            Text {
                text: root.present ? root.monitor.statusText : ""
                color: root.statusColor(root.present ? root.monitor.status : "up")
                font.family: root.fontFamily
                font.pixelSize: Style.font.subtitle
                font.bold: true
                textFormat: Text.PlainText
            }

            // How long it has held that status — the difference between a
            // service that just fell over and one nobody has noticed all week.
            Text {
                Layout.fillWidth: true
                text: root.present ? root.monitor.held : ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
                textFormat: Text.PlainText
            }

            Text {
                Layout.alignment: Qt.AlignVCenter
                Layout.maximumWidth: parent.width / 3
                text: root.present ? root.monitor.name : ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                horizontalAlignment: Text.AlignRight
                elide: Text.ElideLeft
                textFormat: Text.PlainText
            }
        }

        // -------------------------------------------------- the recent history
        //
        // One bar per heartbeat, oldest at the left: height is latency against
        // the slowest check in the window, colour is Status. A failure is drawn
        // full height so the eye lands on it rather than reading it as a fast
        // check.
        Item {
            id: spark

            readonly property var samples: root.present ? root.monitor.samples : []
            readonly property int gap: Style.spacing.hairline
            // Wide enough to see, never so wide that eight heartbeats look like
            // a bar chart.
            readonly property real barWidth:
                samples.length > 0
                    ? Math.min(
                          Style.space(6),
                          Math.max(1, (width - (samples.length - 1) * gap) / samples.length)
                      )
                    : 0

            Layout.fillWidth: true
            Layout.preferredHeight: Style.space(24)
            visible: samples.length > 0

            Rectangle {
                anchors.fill: parent
                radius: Style.space(4)
                color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.05)
            }

            Row {
                id: bars
                anchors.left: parent.left
                anchors.right: parent.right
                height: parent.height
                spacing: spark.gap
                clip: true

                Repeater {
                    model: spark.samples

                    Rectangle {
                        required property var modelData

                        width: spark.barWidth
                        height: Math.max(1, Math.round(bars.height * modelData.level))
                        y: bars.height - height
                        radius: Style.spacing.hairline
                        color: root.statusColor(modelData.status)
                    }
                }
            }
        }

        // ------------------------------------------------------------- the figures
        RowLayout {
            Layout.fillWidth: true
            spacing: Style.spacing.huge

            Fact {
                label: "24H UPTIME"
                value: root.present ? root.monitor.uptimeText : ""
            }

            Fact {
                label: "LATENCY"
                value: root.present ? root.monitor.latencyText : ""
            }

            Fact {
                label: "24H AVERAGE"
                value: root.present ? root.monitor.avgPingText : ""
            }

            Fact {
                label: "CERTIFICATE"
                value: root.present ? root.monitor.certText : ""
            }

            Item {
                Layout.fillWidth: true
            }
        }
    }
}
