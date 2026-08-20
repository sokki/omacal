import QtQuick
import "."
import "Calendar.js" as Cal

// Twelve mini months, Apple's year view: today carries the accent circle,
// clicking a day opens it in the day view, clicking a month name opens the
// month view.
Item {
    id: yearView

    readonly property int columns: width > height * 1.1 ? 4 : 3
    readonly property int rows: Math.ceil(12 / columns)

    Grid {
        anchors.fill: parent
        anchors.margins: win.scaledSize(20)
        columns: yearView.columns
        columnSpacing: win.scaledSize(24)
        rowSpacing: win.scaledSize(16)

        Repeater {
            model: 12

            Item {
                required property int index
                width: (yearView.width - win.scaledSize(40)
                    - (yearView.columns - 1) * win.scaledSize(24)) / yearView.columns
                height: (yearView.height - win.scaledSize(40)
                    - (yearView.rows - 1) * win.scaledSize(16)) / yearView.rows

                MiniMonth {
                    // Grow the day rows so the twelve months fill the page
                    // instead of clustering at the top of their cells.
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    cellSize: Math.max(win.scaledSize(18),
                        (parent.height - win.scaledSize(30)) / 6)
                    monthDate: new Date(win.focusedDate.getFullYear(), parent.index, 1)
                    selectedDate: win.focusedDate
                    dimOtherMonths: false
                    dayFontSize: Math.max(Style.font.bodySmall,
                                          Math.min(Style.font.heading, cellSize * 0.5))
                    onDayClicked: function(day) { win.showDay(day); }
                    onTitleClicked: {
                        win.focusedDate = new Date(win.focusedDate.getFullYear(),
                                                   parent.index, 1);
                        win.setViewMode("month");
                    }
                }
            }
        }
    }
}
