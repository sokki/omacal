import QtQuick
import "."
import "Calendar.js" as Cal

// One row segment of a multi-day bar, shared by the month grid and the
// all-day shelf: calendar-colored fill with an elided title, square-cornered
// on any edge where the event continues beyond the visible range. Pure
// visual — each view layers its own interaction on top.
Rectangle {
    id: bar

    required property var event
    required property bool selected
    required property bool clipLeft
    required property bool clipRight

    readonly property color eventColor: win.calendarColor(event.calendarId)
    // Selection darkens the whole bar, every segment of it.
    readonly property color fillColor: selected
        ? Qt.darker(eventColor, 1.35) : eventColor

    color: fillColor
    topLeftRadius: clipLeft ? 0 : win.scaledSize(4)
    bottomLeftRadius: clipLeft ? 0 : win.scaledSize(4)
    topRightRadius: clipRight ? 0 : win.scaledSize(4)
    bottomRightRadius: clipRight ? 0 : win.scaledSize(4)

    Text {
        anchors.fill: parent
        anchors.leftMargin: win.scaledSize(6)
        anchors.rightMargin: win.scaledSize(4)
        text: Cal.displayTitle(bar.event)
        color: win.contrastOn(bar.fillColor)
        elide: Text.ElideRight
        verticalAlignment: Text.AlignVCenter
        font.family: win.uiFont
        font.pixelSize: Style.font.bodySmall
    }
}
