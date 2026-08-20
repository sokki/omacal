import QtQuick
import "."
import QtQuick.Controls

// Flat themed combo box: the Basic style's stock popup and rows do not
// follow the omarchy palette, so every piece is drawn here. Shared by the
// event editor and the custom repeat sheet.
ComboBox {
    id: combo

    property color textColor: win.inkColor

    function selectIndex(index) {
        currentIndex = index;
        popup.close();
        activated(index);
    }

    font.family: win.uiFont
    font.pixelSize: Style.font.body

    indicator: Text {
        anchors.right: parent.right
        anchors.rightMargin: win.scaledSize(8)
        anchors.verticalCenter: parent.verticalCenter
        text: "▾"
        color: win.mutedColor
        font.pixelSize: Style.font.caption
    }
    contentItem: Text {
        leftPadding: win.scaledSize(8)
        rightPadding: win.scaledSize(18)
        text: combo.displayText
        color: combo.textColor
        elide: Text.ElideRight
        verticalAlignment: Text.AlignVCenter
        font: combo.font
    }
    background: Rectangle {
        implicitHeight: win.scaledSize(26)
        radius: win.scaledSize(5)
        color: combo.hovered ? win.hoverColor : win.panelColor
        border.color: win.lineColor
    }
    delegate: AbstractButton {
        id: comboRow
        required property var modelData
        required property int index
        width: combo.width - win.scaledSize(8)
        height: win.scaledSize(24)
        // The selection runs on the combo, never in the delegate: closing the
        // popup destroys the delegate, and handlers routinely replace the
        // model (repeat rules, alert rows) — either would abort the rest of a
        // handler that lived here, stranding the popup open or swallowing the
        // notification.
        onClicked: combo.selectIndex(index)
        background: Rectangle {
            radius: win.scaledSize(4)
            color: comboRow.hovered || combo.highlightedIndex === comboRow.index
                ? win.hoverColor : "transparent"
        }
        contentItem: Text {
            leftPadding: win.scaledSize(6)
            text: combo.textRole !== ""
                ? comboRow.modelData[combo.textRole] : comboRow.modelData
            color: win.inkColor
            elide: Text.ElideRight
            verticalAlignment: Text.AlignVCenter
            font: combo.font
        }
    }
    popup: Popup {
        y: combo.height + win.scaledSize(2)
        width: combo.width
        padding: win.scaledSize(4)
        implicitHeight: Math.min(contentItem.implicitHeight + topPadding + bottomPadding,
                                 win.scaledSize(280))
        contentItem: ListView {
            clip: true
            implicitHeight: contentHeight
            model: combo.popup.visible ? combo.delegateModel : null
            currentIndex: combo.highlightedIndex
        }
        background: Rectangle {
            color: win.popupColor
            border.color: win.lineColor
            radius: win.scaledSize(6)
        }
    }
}
