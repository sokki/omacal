import QtQuick
import "."
import "Calendar.js" as Cal

// The month grid: fixed weekday header, one cell per day. All-day and
// multi-day events run as continuous bars across their week row — a bar that
// continues past the row's edge is drawn flush to it, square-cornered, and
// picks up on the next row. Single-day timed events remain per-cell chips
// with a dot, title, and start time; overflow collapses into an "N more"
// line that jumps to the day view, like Apple Calendar.
Item {
    id: monthView

    readonly property var gridStart: Cal.monthGridStart(win.focusedDate, win.firstDayOfWeek)
    // Always six weeks, like the mini month: the grid keeps a constant
    // rhythm instead of reflowing between five- and six-week months.
    readonly property int rows: 6
    readonly property date today: win.todayDate

    readonly property int chipHeight: win.scaledSize(18)
    readonly property int chipSpacing: win.scaledSize(2)
    readonly property int cellPadding: win.scaledSize(3)
    readonly property int dayNumberHeight: win.scaledSize(20)

    // Vertical offset of slot k inside a cell; bars and chips share slots so
    // they line up across cell boundaries.
    function slotY(slot) {
        return cellPadding + dayNumberHeight + chipSpacing
            + slot * (chipHeight + chipSpacing);
    }
    readonly property int slotRoom: Math.max(0, Math.floor(
        (gridArea.height / rows - slotY(0) - cellPadding) / (chipHeight + chipSpacing)))

    // The laid-out week bars plus, per visible day: the lanes bars reserve,
    // the count of bars hidden by lack of room, and the timed chips.
    property var barSegments: []
    property var lanesByDay: []
    property var hiddenByDay: []
    property var chipsByDay: []

    // Drag state: the day an event is being dropped on, the floating copy of
    // the event under the cursor, and the inclusive day range being
    // rubber-banded for a new all-day event.
    property int dropDayIndex: -1
    property var dragGhost: null
    property int createAnchorIndex: -1
    property int createCurrentIndex: -1

    // The editor's still-open draft (all-day only here) keeps its dragged-out
    // day range highlighted while the create popover is up.
    readonly property var draftRange: win.draftEvent !== null && win.draftEvent.allDay
        ? Cal.spanColumns(win.draftEvent, gridStart, rows * 7) : null

    function updateDragGhost(area, mouse, event, tint) {
        var point = area.mapToItem(gridArea, mouse.x, mouse.y);
        dragGhost = {
            x: point.x,
            y: point.y,
            title: Cal.displayTitle(event),
            color: "" + tint
        };
    }

    function dayIndexAt(item, x, y) {
        var point = item.mapToItem(gridArea, x, y);
        var col = Math.max(0, Math.min(6, Math.floor(point.x / gridArea.cellWidth)));
        var row = Math.max(0, Math.min(rows - 1,
            Math.floor(point.y / gridArea.cellHeight)));
        return row * 7 + col;
    }

    // The cell a new event would land in; see Main.newEventAnchor.
    function rectForRange(startMs, endMs, allDay) {
        var index = Cal.daysBetween(gridStart, Cal.startOfDay(new Date(startMs)));
        return index >= 0 && index < rows * 7 ? cellRect(index) : null;
    }

    function cellRect(index) {
        return gridArea.mapToItem(null,
            (index % 7) * gridArea.cellWidth,
            Math.floor(index / 7) * gridArea.cellHeight,
            gridArea.cellWidth, gridArea.cellHeight);
    }

    // Moves by how far the cursor travelled, not by where the event starts:
    // grabbing a multi-day bar on its Thursday and dropping it one cell right
    // must move the whole bar one day.
    function moveEventBy(event, grabIndex, dropIndex) {
        if (grabIndex < 0 || dropIndex < 0 || grabIndex === dropIndex)
            return;
        win.commitEventUpdate(event, Cal.shiftEventByDays(event, dropIndex - grabIndex));
    }

    function rebuildLayout() {
        var dayCount = rows * 7;
        var lanes = [];
        var hidden = [];
        var chips = [];
        for (var i = 0; i < dayCount; i++) {
            lanes.push(0);
            hidden.push(0);
            chips.push([]);
        }

        // The bottom slot stays reserved for chips or the "more" line.
        var barCap = Math.max(0, slotRoom - 1);
        var segments = [];

        // One pass over the store's (months-wide) cache; the per-week and
        // per-day loops below only ever see this grid's events. Bars and
        // chips split here, so the per-week bar layout walks only the bars
        // and each chip lands in its day bucket without a per-cell scan.
        var events = Cal.eventsInRange(store.events, gridStart.getTime(),
                                       Cal.addDays(gridStart, dayCount).getTime());
        var barEvents = [];
        for (var e = 0; e < events.length; e++) {
            if (Cal.isBarEvent(events[e])) {
                barEvents.push(events[e]);
                continue;
            }
            // A non-bar event occupies exactly its start day.
            var day = Cal.daysBetween(gridStart,
                                      Cal.startOfDay(new Date(events[e].startMs)));
            if (day >= 0 && day < dayCount)
                chips[day].push(events[e]);
        }
        for (var c = 0; c < dayCount; c++)
            chips[c].sort(function(a, b) { return a.startMs - b.startMs; });

        for (var w = 0; w < rows; w++) {
            var weekStart = Cal.addDays(gridStart, w * 7);
            var weekSegments = Cal.layoutBars(barEvents, weekStart, 7);
            for (var s = 0; s < weekSegments.length; s++) {
                var segment = weekSegments[s];
                if (segment.lane >= barCap) {
                    for (var h = segment.startCol; h <= segment.endCol; h++)
                        hidden[w * 7 + h]++;
                    continue;
                }
                segment.week = w;
                segments.push(segment);
                for (var d = segment.startCol; d <= segment.endCol; d++) {
                    var day = w * 7 + d;
                    lanes[day] = Math.max(lanes[day], segment.lane + 1);
                }
            }
        }

        barSegments = segments;
        lanesByDay = lanes;
        hiddenByDay = hidden;
        chipsByDay = chips;
    }

    // Deferred so a burst of triggers — an interactive window resize walks
    // slotRoom every frame — costs one rebuild per event-loop pass.
    Connections {
        target: store
        function onEventsChanged() { Qt.callLater(monthView.rebuildLayout); }
    }
    onGridStartChanged: Qt.callLater(monthView.rebuildLayout)
    onSlotRoomChanged: Qt.callLater(monthView.rebuildLayout)
    Component.onCompleted: rebuildLayout()

    // Chips and bars share one drag state machine, filling the visual they
    // sit on: press-move past a small threshold becomes a move (drop-target
    // outline plus floating ghost), release drops it or, for a plain click,
    // selects; double click opens the editor anchored to the visual.
    component EventDragArea: MouseArea {
        required property var event
        required property color tint

        anchors.fill: parent

        property real pressX: 0
        property real pressY: 0
        property bool moving: false
        property int grabIndex: -1

        onPressed: function(mouse) {
            pressX = mouse.x;
            pressY = mouse.y;
            moving = false;
            grabIndex = monthView.dayIndexAt(this, mouse.x, mouse.y);
        }
        onPositionChanged: function(mouse) {
            if (!pressed || win.calendarReadOnly(event.calendarId))
                return;
            if (Math.abs(mouse.x - pressX) > win.scaledSize(4)
                    || Math.abs(mouse.y - pressY) > win.scaledSize(4))
                moving = true;
            if (moving) {
                monthView.dropDayIndex =
                    monthView.dayIndexAt(this, mouse.x, mouse.y);
                monthView.updateDragGhost(this, mouse, event, tint);
            }
        }
        onReleased: {
            var target = monthView.dropDayIndex;
            monthView.dropDayIndex = -1;
            monthView.dragGhost = null;
            if (moving) {
                moving = false;
                monthView.moveEventBy(event, grabIndex, target);
                return;
            }
            win.selectEvent(event);
        }
        onCanceled: {
            moving = false;
            monthView.dropDayIndex = -1;
            monthView.dragGhost = null;
        }
        onDoubleClicked: {
            win.selectEvent(event);
            editor.openForEvent(event,
                parent.mapToItem(null, 0, 0, parent.width, parent.height));
        }
    }

    Column {
        anchors.fill: parent

        Row {
            id: weekdayHeader
            width: parent.width
            height: win.scaledSize(26)

            Repeater {
                model: 7

                Text {
                    required property int index
                    readonly property int jsDay: (monthView.gridStart.getDay() + index) % 7
                    width: parent.width / 7
                    height: parent.height
                    text: Cal.localeDayName(jsDay, Locale.ShortFormat)
                    color: jsDay === 0 || jsDay === 6 ? win.mutedColor : win.inkColor
                    font.family: win.uiFont
                    font.pixelSize: Style.font.body
                    horizontalAlignment: Text.AlignRight
                    rightPadding: win.scaledSize(8)
                    verticalAlignment: Text.AlignVCenter
                }
            }
        }

        Item {
            id: gridArea
            width: parent.width
            height: parent.height - weekdayHeader.height

            readonly property real cellWidth: width / 7
            readonly property real cellHeight: height / monthView.rows

            Grid {
                anchors.fill: parent
                columns: 7

                Repeater {
                    model: monthView.rows * 7

                    Rectangle {
                        id: cell
                        required property int index
                        readonly property date day: Cal.addDays(monthView.gridStart, index)
                        readonly property bool inMonth: Cal.sameMonth(day, win.focusedDate)
                        readonly property bool isToday: Cal.sameDay(day, monthView.today)
                        readonly property bool isFocused: Cal.sameDay(day, win.focusedDate)
                        readonly property var dayChips: monthView.chipsByDay.length > index
                            ? monthView.chipsByDay[index] : []
                        readonly property int laneOffset: monthView.lanesByDay.length > index
                            ? monthView.lanesByDay[index] : 0
                        readonly property int hiddenCount: monthView.hiddenByDay.length > index
                            ? monthView.hiddenByDay[index] : 0

                        readonly property int availableSlots:
                            Math.max(0, monthView.slotRoom - laneOffset)
                        readonly property bool needMore: hiddenCount > 0
                            || dayChips.length > availableSlots
                        readonly property int shownChips: Math.min(dayChips.length,
                            needMore ? Math.max(0, availableSlots - 1) : dayChips.length)
                        readonly property int moreCount: Math.max(0,
                            hiddenCount + dayChips.length - shownChips)

                        width: gridArea.cellWidth
                        height: gridArea.cellHeight
                        color: inMonth ? "transparent" : win.panelColor

                        readonly property bool createHighlight:
                            (monthView.createAnchorIndex >= 0
                                && index >= Math.min(monthView.createAnchorIndex,
                                                     monthView.createCurrentIndex)
                                && index <= Math.max(monthView.createAnchorIndex,
                                                     monthView.createCurrentIndex))
                            || (monthView.draftRange !== null
                                && index >= monthView.draftRange.startCol
                                && index <= monthView.draftRange.endCol)
                        readonly property bool dropHighlight:
                            monthView.dropDayIndex === index

                        // Shared cell borders: every cell draws its top and left edge.
                        Rectangle {
                            anchors.top: parent.top; width: parent.width; height: 1
                            color: win.lineColor
                        }
                        Rectangle {
                            anchors.left: parent.left; height: parent.height; width: 1
                            color: win.lineColor
                            visible: cell.index % 7 !== 0
                        }

                        // Rubber-band range for a new event: accent fill.
                        Rectangle {
                            anchors.fill: parent
                            visible: cell.createHighlight
                            color: win.mixColors(win.pageColor, win.accentColor, 0.15)
                            border.color: win.accentColor
                        }
                        // Drop target while moving an event: outline only —
                        // the dragged event itself travels as the ghost.
                        Rectangle {
                            anchors.fill: parent
                            visible: cell.dropHighlight
                            color: "transparent"
                            border.color: win.accentColor
                        }

                        // Drag across days to rubber-band a new all-day event
                        // (the month view creates all-day events only); a
                        // plain click focuses the day, a double click creates
                        // a one-day event directly.
                        MouseArea {
                            anchors.fill: parent

                            property real pressX: 0
                            property real pressY: 0
                            property bool creating: false
                            // The day this gesture began on. A double click's
                            // second press lands after the grid has already
                            // re-dated itself, so it must not overwrite this.
                            property date armedDay: new Date()
                            property double lastPressMs: 0

                            onPressed: function(mouse) {
                                var now = Date.now();
                                if (now - lastPressMs > 450)
                                    armedDay = cell.day;
                                lastPressMs = now;
                                pressX = mouse.x;
                                pressY = mouse.y;
                                creating = false;
                            }
                            onPositionChanged: function(mouse) {
                                if (!pressed)
                                    return;
                                if (Math.abs(mouse.x - pressX) > win.scaledSize(4)
                                        || Math.abs(mouse.y - pressY) > win.scaledSize(4))
                                    creating = true;
                                if (!creating)
                                    return;
                                monthView.createAnchorIndex = cell.index;
                                monthView.createCurrentIndex =
                                    monthView.dayIndexAt(this, mouse.x, mouse.y);
                            }
                            onReleased: {
                                var lo = Math.min(cell.index, monthView.createCurrentIndex);
                                var hi = Math.max(cell.index, monthView.createCurrentIndex);
                                monthView.createAnchorIndex = -1;
                                monthView.createCurrentIndex = -1;
                                if (!creating) {
                                    win.focusedDate = cell.day;
                                    win.clearSelection();
                                    return;
                                }
                                creating = false;
                                var start = Cal.addDays(monthView.gridStart, lo);
                                var end = Cal.addDays(monthView.gridStart, hi + 1);
                                editor.openForCreate(start.getTime(), end.getTime(), true,
                                                     monthView.cellRect(hi));
                            }
                            onCanceled: {
                                creating = false;
                                monthView.createAnchorIndex = -1;
                                monthView.createCurrentIndex = -1;
                            }
                            onDoubleClicked: {
                                editor.openForCreate(armedDay.getTime(),
                                                     Cal.addDays(armedDay, 1).getTime(), true,
                                                     cell.mapToItem(null, 0, 0,
                                                                    cell.width, cell.height));
                            }
                        }

                        Item {
                            anchors.fill: parent
                            anchors.margins: monthView.cellPadding

                            Rectangle {
                                anchors.right: parent.right
                                // A pill rather than a circle: "Sep 1" on the
                                // first of a month needs the extra room.
                                width: Math.max(win.scaledSize(20),
                                    dayNumber.implicitWidth + win.scaledSize(8))
                                height: win.scaledSize(20)
                                radius: height / 2
                                color: cell.isToday ? win.accentColor : "transparent"
                                border.color: cell.isFocused && !cell.isToday
                                    ? win.accentColor : "transparent"

                                Text {
                                    id: dayNumber
                                    anchors.centerIn: parent
                                    text: cell.day.getDate() === 1
                                        ? Qt.formatDate(cell.day, "MMM d") : cell.day.getDate()
                                    color: cell.isToday ? win.contrastOn(win.accentColor)
                                        : cell.inMonth ? win.inkColor : win.mutedColor
                                    font.family: win.uiFont
                                    font.bold: cell.isToday || cell.day.getDate() === 1
                                    font.pixelSize: Style.font.body
                                }
                            }

                            Repeater {
                                model: cell.shownChips

                                Item {
                                    id: chip
                                    required property int index
                                    readonly property var event: cell.dayChips[index]
                                    readonly property color eventColor:
                                        win.calendarColor(event.calendarId)
                                    readonly property bool selected: win.isEventSelected(event)

                                    // Chips start below the bar lanes covering this day.
                                    y: monthView.slotY(cell.laneOffset + index)
                                        - monthView.cellPadding
                                    width: parent.width
                                    height: monthView.chipHeight

                                    // Selection fills the chip with its calendar color.
                                    Rectangle {
                                        anchors.fill: parent
                                        radius: win.scaledSize(4)
                                        color: chip.eventColor
                                        visible: chip.selected
                                    }

                                    Row {
                                        anchors.fill: parent
                                        anchors.leftMargin: win.scaledSize(4)
                                        anchors.rightMargin: win.scaledSize(4)
                                        spacing: win.scaledSize(4)

                                        Rectangle {
                                            anchors.verticalCenter: parent.verticalCenter
                                            width: win.scaledSize(6)
                                            height: width
                                            radius: width / 2
                                            color: chip.selected
                                                ? win.contrastOn(chip.eventColor) : chip.eventColor
                                        }
                                        Text {
                                            anchors.verticalCenter: parent.verticalCenter
                                            width: parent.width - win.scaledSize(10)
                                                - (timeLabel.visible
                                                    ? timeLabel.width + win.scaledSize(4) : 0)
                                            text: Cal.displayTitle(chip.event)
                                            color: chip.selected
                                                ? win.contrastOn(chip.eventColor) : win.inkColor
                                            elide: Text.ElideRight
                                            font.family: win.uiFont
                                            font.pixelSize: Style.font.bodySmall
                                        }
                                        Text {
                                            id: timeLabel
                                            anchors.verticalCenter: parent.verticalCenter
                                            // Only worth its space while it stays a
                                            // modest fraction of the cell.
                                            visible: implicitWidth <= chip.width * 0.3
                                            text: Cal.formatTime(chip.event.startMs)
                                            color: chip.selected
                                                ? win.contrastOn(chip.eventColor) : win.mutedColor
                                            font.family: win.uiFont
                                            font.pixelSize: Style.font.caption
                                        }
                                    }

                                    opacity: chipArea.moving ? 0.5 : 1

                                    EventDragArea {
                                        id: chipArea
                                        event: chip.event
                                        tint: chip.eventColor
                                    }
                                }
                            }

                            Text {
                                visible: cell.needMore && cell.moreCount > 0
                                y: monthView.slotY(cell.laneOffset + cell.shownChips)
                                    - monthView.cellPadding
                                text: qsTr("%1 more").arg(cell.moreCount)
                                color: win.mutedColor
                                font.family: win.uiFont
                                font.pixelSize: Style.font.caption
                                leftPadding: win.scaledSize(4)

                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: win.showDay(cell.day)
                                }
                            }
                        }
                    }
                }
            }

            // The week-spanning bars, drawn over the grid so they can cross
            // cell boundaries as one rectangle per week row.
            Repeater {
                model: monthView.barSegments

                EventBar {
                    id: bar
                    required property var modelData

                    event: modelData.event
                    selected: win.isEventSelected(event)
                    clipLeft: modelData.clipLeft
                    clipRight: modelData.clipRight

                    x: modelData.startCol * gridArea.cellWidth
                        + (modelData.clipLeft ? 0 : monthView.cellPadding)
                    y: modelData.week * gridArea.cellHeight + monthView.slotY(modelData.lane)
                    width: (modelData.endCol - modelData.startCol + 1) * gridArea.cellWidth
                        - (modelData.clipLeft ? 0 : monthView.cellPadding)
                        - (modelData.clipRight ? 0 : monthView.cellPadding)
                    height: monthView.chipHeight
                    opacity: barArea.moving ? 0.5 : 1

                    EventDragArea {
                        id: barArea
                        event: bar.event
                        tint: bar.eventColor
                    }
                }
            }

            // The dragged event travels with the cursor as a floating copy.
            Rectangle {
                visible: monthView.dragGhost !== null
                x: (monthView.dragGhost ? monthView.dragGhost.x : 0) - width / 2
                y: (monthView.dragGhost ? monthView.dragGhost.y : 0) - height / 2
                width: gridArea.cellWidth - win.scaledSize(6)
                height: monthView.chipHeight
                radius: win.scaledSize(4)
                color: monthView.dragGhost ? monthView.dragGhost.color : "transparent"
                opacity: 0.9

                Text {
                    anchors.fill: parent
                    anchors.leftMargin: win.scaledSize(6)
                    anchors.rightMargin: win.scaledSize(4)
                    text: monthView.dragGhost ? monthView.dragGhost.title : ""
                    color: monthView.dragGhost
                        ? win.contrastOn(Qt.color(monthView.dragGhost.color)) : win.inkColor
                    elide: Text.ElideRight
                    verticalAlignment: Text.AlignVCenter
                    font.family: win.uiFont
                    font.pixelSize: Style.font.bodySmall
                }
            }
        }
    }
}
