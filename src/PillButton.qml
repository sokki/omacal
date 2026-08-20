import QtQuick
import "."
import QtQuick.Controls

// The standard pill action button in its three recurring roles: "plain"
// outlined cancel, "accent" filled primary, "danger" outlined destructive.
AbstractButton {
    id: pill

    property string kind: "plain"

    implicitHeight: win.scaledSize(28)
    implicitWidth: pillLabel.implicitWidth + win.scaledSize(kind === "accent" ? 24 : 20)

    background: Rectangle {
        radius: win.scaledSize(6)
        color: pill.kind === "accent"
            ? (pill.hovered
                ? win.mixColors(win.accentColor, win.inkColor, 0.15) : win.accentColor)
            : pill.kind === "danger"
                ? (pill.hovered
                    ? win.mixColors(win.pageColor, win.dangerColor, 0.2) : "transparent")
                : (pill.hovered ? win.hoverColor : "transparent")
        border.color: pill.kind === "danger" ? win.dangerColor
            : pill.kind === "plain" ? win.lineColor : "transparent"
    }
    contentItem: Text {
        id: pillLabel
        text: pill.text
        color: pill.kind === "accent" ? win.contrastOn(win.accentColor)
            : pill.kind === "danger" ? win.dangerColor : win.mutedColor
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        font.family: win.uiFont
        font.bold: pill.kind === "accent"
        font.pixelSize: Style.font.body
    }
}
