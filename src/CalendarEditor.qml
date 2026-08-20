import QtQuick
import "."
import QtQuick.Controls
import QtQuick.Layouts

// Right-click surface for a sidebar calendar: rename it and pick its color.
// Both live on the EDS source, so the change reaches every other client.
Popup {
    id: sheet

    property string calendarId: ""
    property bool editable: true
    property color chosenColor: win.accentColor

    // The omarchy theme's own palette first, then a spread of the colors
    // other calendar apps use, so a calendar can look the same everywhere.
    readonly property var swatches: {
        var list = backend.themePalette.slice();
        var extras = ["#4a90d9", "#6bbd68", "#e0843c", "#c586c0", "#e05555",
                      "#3fb8af", "#9b8bd6", "#8f8f8f"];
        for (var i = 0; i < extras.length; i++)
            if (list.indexOf(extras[i]) === -1)
                list.push(extras[i]);
        return list;
    }

    function openFor(calendar, point) {
        calendarId = calendar.id;
        editable = calendar.writable === true;
        nameField.text = calendar.name;
        chosenColor = calendar.color !== "" ? calendar.color
                                            : win.calendarColor(calendar.id);
        x = Math.min(point.x, win.width - width - win.scaledSize(8));
        y = Math.min(point.y, win.height - implicitHeight - win.scaledSize(8));
        open();
        nameField.forceActiveFocus();
        nameField.selectAll();
    }

    function apply() {
        store.setCalendarProperties(calendarId, nameField.text, "" + chosenColor);
        close();
    }

    parent: Overlay.overlay
    width: win.scaledSize(260)
    padding: win.scaledSize(12)
    modal: true
    focus: true

    background: Rectangle {
        color: win.popupColor
        border.color: win.lineColor
        radius: win.scaledSize(10)
    }

    contentItem: ColumnLayout {
        spacing: win.scaledSize(10)

        TextField {
            id: nameField
            Layout.fillWidth: true
            readOnly: !sheet.editable
            placeholderText: qsTr("Calendar name")
            color: win.inkColor
            placeholderTextColor: win.faintColor
            font.family: win.uiFont
            font.bold: true
            font.pixelSize: Style.font.subtitle
            background: Rectangle {
                radius: win.scaledSize(5)
                color: win.panelColor
                border.color: nameField.activeFocus ? win.accentColor : win.lineColor
            }
            onAccepted: sheet.apply()
        }

        Grid {
            Layout.fillWidth: true
            columns: 8
            spacing: win.scaledSize(6)

            Repeater {
                model: sheet.swatches

                AbstractButton {
                    id: swatch
                    required property var modelData
                    readonly property bool picked:
                        Qt.color(modelData) === Qt.color(sheet.chosenColor)

                    enabled: sheet.editable
                    implicitWidth: win.scaledSize(22)
                    implicitHeight: win.scaledSize(22)
                    onClicked: sheet.chosenColor = modelData

                    background: Rectangle {
                        radius: width / 2
                        color: swatch.modelData
                        border.color: swatch.picked ? win.inkColor
                            : swatch.hovered ? win.mutedColor : "transparent"
                        border.width: swatch.picked ? Math.max(2, win.scaledSize(2)) : 1
                    }
                    contentItem: Text {
                        visible: swatch.picked
                        text: "✓"
                        color: win.contrastOn(Qt.color(swatch.modelData))
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        font.family: win.uiFont
                        font.bold: true
                        font.pixelSize: Style.font.caption
                    }
                }
            }
        }

        Text {
            Layout.fillWidth: true
            visible: !sheet.editable
            text: qsTr("This calendar is managed elsewhere and cannot be edited here.")
            color: win.mutedColor
            wrapMode: Text.Wrap
            font.family: win.uiFont
            font.pixelSize: Style.font.caption
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: win.scaledSize(6)

            Item { Layout.fillWidth: true }

            PillButton {
                text: qsTr("Cancel")
                onClicked: sheet.close()
            }
            PillButton {
                kind: "accent"
                text: qsTr("Done")
                visible: sheet.editable
                onClicked: sheet.apply()
            }
        }
    }
}
