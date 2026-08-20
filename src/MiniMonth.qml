import QtQuick
import "."
import "Calendar.js" as Cal

// A compact month grid: the sidebar navigator and the year view's months are
// both this component. Days outside the month are hidden, matching Apple's
// year view, unless the navigator variant wants them dimmed instead.
Column {
    id: mini

    property date monthDate: new Date()
    property date selectedDate: new Date(NaN)
    property bool showNav: false
    property bool dimOtherMonths: showNav
    property real dayFontSize: Style.font.caption
    // Height of one day row; the year view grows this to fill its cells.
    property real cellSize: win.scaledSize(18)

    signal dayClicked(date day)
    signal monthShifted(int step)
    signal titleClicked()

    readonly property var gridStart: Cal.monthGridStart(monthDate, win.firstDayOfWeek)
    // Always six rows, so the sidebar navigator keeps the same height
    // regardless of how many weeks the shown month spans.
    readonly property int rows: 6
    readonly property date today: win.todayDate

    spacing: win.scaledSize(3)

    Item {
        width: parent.width
        height: win.scaledSize(18)

        Text {
            id: titleText
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: mini.showNav ? Qt.formatDate(mini.monthDate, "MMMM yyyy")
                               : Qt.formatDate(mini.monthDate, "MMMM")
            color: Cal.sameMonth(mini.monthDate, mini.today) ? win.accentColor : win.inkColor
            font.family: win.uiFont
            font.bold: true
            font.pixelSize: Style.font.bodySmall

            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: mini.titleClicked()
            }
        }

        Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: win.scaledSize(2)
            visible: mini.showNav

            Repeater {
                model: [
                    { label: "‹", step: -1 },
                    { label: "›", step: 1 }
                ]

                Text {
                    required property var modelData
                    text: modelData.label
                    color: navArea.containsMouse ? win.inkColor : win.mutedColor
                    font.family: win.uiFont
                    font.pixelSize: Style.font.body
                    width: win.scaledSize(16)
                    horizontalAlignment: Text.AlignHCenter

                    MouseArea {
                        id: navArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: mini.monthShifted(parent.modelData.step)
                    }
                }
            }
        }
    }

    Row {
        width: parent.width

        Repeater {
            model: 7

            Text {
                required property int index
                readonly property int jsDay: (mini.gridStart.getDay() + index) % 7
                width: mini.width / 7
                text: Cal.localeDayName(jsDay, Locale.NarrowFormat)
                color: win.mutedColor
                font.family: win.uiFont
                font.pixelSize: mini.dayFontSize
                horizontalAlignment: Text.AlignHCenter
            }
        }
    }

    Grid {
        width: parent.width
        columns: 7

        Repeater {
            model: mini.rows * 7

            Item {
                id: dayCell
                required property int index
                readonly property date day: Cal.addDays(mini.gridStart, index)
                readonly property bool inMonth: Cal.sameMonth(day, mini.monthDate)
                readonly property bool isToday: Cal.sameDay(day, mini.today)
                readonly property bool isSelected: !isNaN(mini.selectedDate.getTime())
                    && Cal.sameDay(day, mini.selectedDate)

                width: mini.width / 7
                height: mini.cellSize

                Rectangle {
                    anchors.centerIn: parent
                    width: Math.min(mini.cellSize - win.scaledSize(2),
                                    mini.width / 7 - win.scaledSize(2))
                    height: width
                    radius: width / 2
                    color: dayCell.isToday ? win.accentColor
                        : dayCell.isSelected ? win.hoverColor : "transparent"
                    visible: dayCell.inMonth || mini.dimOtherMonths
                }

                Text {
                    anchors.centerIn: parent
                    text: dayCell.day.getDate()
                    visible: dayCell.inMonth || mini.dimOtherMonths
                    color: dayCell.isToday ? win.contrastOn(win.accentColor)
                        : dayCell.inMonth ? win.inkColor : win.faintColor
                    font.family: win.uiFont
                    font.pixelSize: mini.dayFontSize
                }

                MouseArea {
                    anchors.fill: parent
                    enabled: dayCell.inMonth || mini.dimOtherMonths
                    cursorShape: Qt.PointingHandCursor
                    onClicked: mini.dayClicked(dayCell.day)
                }
            }
        }
    }
}
