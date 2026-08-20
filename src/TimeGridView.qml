import QtQuick
import "."
import "Calendar.js" as Cal

// The day and week views: an all-day shelf over a scrollable 24-hour grid.
// Overlapping events share their day column Apple-style, the current time is
// a line across today, blocks drag vertically to reschedule in 15-minute
// steps, and empty slots create events on double click.
Item {
    id: timeGrid

    property int dayCount: 7

    readonly property date rangeStart: dayCount === 1
        ? Cal.startOfDay(win.focusedDate)
        : Cal.startOfWeek(win.focusedDate, win.firstDayOfWeek)
    readonly property int gutterWidth: win.scaledSize(56)
    readonly property int hourHeight: win.scaledSize(52)
    readonly property real dayWidth: (width - gutterWidth) / dayCount

    property double nowMs: Date.now()
    Timer {
        interval: 30000
        running: true
        repeat: true
        onTriggered: timeGrid.nowMs = Date.now()
    }

    // Laid-out timed events per day (multi-day timed events span their
    // columns, clamped per day), plus the all-day shelf: all-day events run
    // there as continuous bars with square, marginless edges where they
    // continue beyond the visible range.
    property var timedByDay: []
    property var shelfSegments: []
    property int shelfLanes: 0

    // Live drag-to-create state: a timed span in the hour grid, and an
    // all-day column range on the shelf.
    property var createPreview: null
    property var shelfPreview: null

    // While a press-drag is running anywhere in the grid, the flickable must
    // not steal the pointer; wheel scrolling is unaffected.
    property bool dragLock: false

    // The rubber band lives on after release as the editor's draft event, so
    // the roughed-out span stays visible while the popover is open.
    readonly property var activePreview: createPreview !== null ? createPreview
        : (win.draftEvent !== null && !win.draftEvent.allDay ? win.draftEvent : null)
    readonly property var activeShelfPreview: {
        if (shelfPreview !== null)
            return shelfPreview;
        if (win.draftEvent === null || !win.draftEvent.allDay)
            return null;
        return Cal.spanColumns(win.draftEvent, rangeStart, dayCount);
    }

    function columnAt(x) {
        return Math.max(0, Math.min(dayCount - 1,
            Math.floor((x - gutterWidth) / dayWidth)));
    }

    // The on-screen rectangle a new event would occupy, so a popover opened
    // from the keyboard can hang off the slot instead of the window centre.
    function rectForRange(startMs, endMs, allDay) {
        var col = Cal.daysBetween(rangeStart, Cal.startOfDay(new Date(startMs)));
        if (col < 0 || col >= dayCount)
            return null;
        if (allDay)
            return shelf.mapToItem(null, gutterWidth + col * dayWidth, 0,
                                   dayWidth, shelf.height);

        var day = Cal.addDays(rangeStart, col);
        var contentTop = Cal.dayMinutes(startMs, day) / 60 * hourHeight;
        var height = Math.max(win.scaledSize(20),
            (Cal.dayMinutes(endMs, day) - Cal.dayMinutes(startMs, day)) / 60 * hourHeight);

        // Scroll the slot into view first, so the popover never points at
        // something above or below the visible hours.
        if (contentTop < flick.contentY
                || contentTop + height > flick.contentY + flick.height) {
            flick.contentY = Math.max(0, Math.min(contentTop - hourHeight,
                                                  flick.contentHeight - flick.height));
        }
        return flick.mapToItem(null, gutterWidth + col * dayWidth,
                               contentTop - flick.contentY, dayWidth, height);
    }

    // Every interactive adjustment — create, move, resize — snaps a pixel
    // distance in the hour grid to 15-minute steps.
    function snapDeltaMinutes(dy) {
        return Math.round(dy / hourHeight * 60 / 15) * 15;
    }
    function snappedMinutes(y) {
        return Math.max(0, Math.min(24 * 60, snapDeltaMinutes(y)));
    }

    // Line heights for fitting block content into whatever vertical space an
    // event's duration grants it.
    FontMetrics {
        id: blockTitleMetrics
        font.family: win.uiFont
        font.bold: true
        font.pixelSize: Style.font.bodySmall
    }
    FontMetrics {
        id: blockSubMetrics
        font.family: win.uiFont
        font.pixelSize: Style.font.caption
    }
    function rebuildDays() {
        // One pass over the store's (months-wide) cache; everything below
        // only sees this range's events.
        var events = Cal.eventsInRange(store.events, rangeStart.getTime(),
                                       Cal.addDays(rangeStart, dayCount).getTime());

        // Timed events — multi-day ones included — belong in the hour grid;
        // only genuinely all-day events go to the shelf.
        var timed = [];
        for (var d = 0; d < dayCount; d++) {
            var day = Cal.addDays(rangeStart, d);
            var timedEvents = [];
            for (var e = 0; e < events.length; e++) {
                if (!events[e].allDay && Cal.touchesDay(events[e], day))
                    timedEvents.push(events[e]);
            }
            timed.push(Cal.layoutTimedEvents(timedEvents));
        }
        timedByDay = timed;

        var allDayEvents = [];
        for (var a = 0; a < events.length; a++) {
            if (events[a].allDay)
                allDayEvents.push(events[a]);
        }
        var segments = Cal.layoutBars(allDayEvents, rangeStart, dayCount);
        var lanes = 0;
        for (var s = 0; s < segments.length; s++)
            lanes = Math.max(lanes, segments[s].lane + 1);
        shelfSegments = segments;
        shelfLanes = lanes;
    }

    Connections {
        target: store
        function onEventsChanged() { timeGrid.rebuildDays(); }
    }
    onRangeStartChanged: rebuildDays()
    onDayCountChanged: rebuildDays()
    Component.onCompleted: {
        rebuildDays();
        // Open on the working day: two hours before now when today is on
        // screen, but never so early that the grid shows only empty night.
        var hour = 8;
        var now = new Date();
        for (var d = 0; d < dayCount; d++) {
            if (Cal.sameDay(Cal.addDays(rangeStart, d), now))
                hour = Math.max(7, now.getHours() - 2);
        }
        flick.contentY = Math.min(hour * hourHeight,
                                  Math.max(0, flick.contentHeight - flick.height));
    }

    // A resize handle on one of a block's real edges, mirrored by isStart;
    // it lives inside a block delegate and resolves that block from its
    // instantiation context. The dragged edge stops 15 minutes short of the
    // other one, so an event never collapses or inverts.
    component ResizeHandle: MouseArea {
        required property bool isStart

        anchors.left: parent.left
        anchors.right: parent.right
        height: win.scaledSize(6)
        cursorShape: Qt.SizeVerCursor

        property real pressGridY: 0

        function setDelta(minutes) {
            if (isStart)
                block.resizeStartMinutes = minutes;
            else
                block.resizeEndMinutes = minutes;
        }

        onPressed: function(mouse) {
            pressGridY = mapToItem(gridContent, 0, mouse.y).y;
            setDelta(0);
            timeGrid.dragLock = true;
        }
        onPositionChanged: function(mouse) {
            if (!pressed)
                return;
            var y = mapToItem(gridContent, 0, mouse.y).y;
            var minutes = timeGrid.snapDeltaMinutes(y - pressGridY);
            var duration = (block.event.endMs - block.event.startMs) / 60000;
            setDelta(isStart ? Math.min(minutes, duration - 15)
                             : Math.max(minutes, -(duration - 15)));
        }
        onReleased: {
            timeGrid.dragLock = false;
            var minutes = isStart ? block.resizeStartMinutes
                                  : block.resizeEndMinutes;
            setDelta(0);
            if (minutes === 0)
                return;
            var moved = Cal.cloneForUpdate(block.event);
            if (isStart)
                moved.startMs += minutes * 60000;
            else
                moved.endMs += minutes * 60000;
            win.commitEventUpdate(block.event, moved);
        }
        onCanceled: {
            timeGrid.dragLock = false;
            setDelta(0);
        }
    }

    Column {
        anchors.fill: parent

        // ------------------------------------------------------- day headers
        Row {
            width: parent.width
            height: win.scaledSize(34)

            Item { width: timeGrid.gutterWidth; height: 1 }

            Repeater {
                model: timeGrid.dayCount

                Item {
                    id: dayHeader
                    required property int index
                    readonly property date day: Cal.addDays(timeGrid.rangeStart, index)
                    readonly property bool isToday: Cal.sameDay(day, new Date(timeGrid.nowMs))

                    width: timeGrid.dayWidth
                    height: parent.height

                    Row {
                        anchors.centerIn: parent
                        spacing: win.scaledSize(6)

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: Qt.formatDate(dayHeader.day, "ddd")
                            color: dayHeader.isToday ? win.inkColor : win.mutedColor
                            font.family: win.uiFont
                            font.pixelSize: Style.font.body
                        }
                        Rectangle {
                            width: win.scaledSize(24)
                            height: width
                            radius: width / 2
                            color: dayHeader.isToday ? win.accentColor : "transparent"
                            border.color: !dayHeader.isToday
                                    && Cal.sameDay(dayHeader.day, win.focusedDate)
                                ? win.accentColor : "transparent"

                            Text {
                                anchors.centerIn: parent
                                text: dayHeader.day.getDate()
                                color: dayHeader.isToday
                                    ? win.contrastOn(win.accentColor) : win.inkColor
                                font.family: win.uiFont
                                font.bold: true
                                font.pixelSize: Style.font.subtitle
                            }
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        enabled: timeGrid.dayCount > 1
                        cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                        onClicked: win.showDay(dayHeader.day)
                    }
                }
            }
        }

        // ------------------------------------------------------ all-day shelf
        Item {
            id: shelf
            width: parent.width
            // Always at least one lane tall, so there is an all-day strip to
            // drag new events onto even when none exist yet.
            height: Math.max(1, timeGrid.shelfLanes) * win.scaledSize(20) + win.scaledSize(4)

            Text {
                anchors.right: parent.right
                anchors.rightMargin: parent.width - timeGrid.gutterWidth + win.scaledSize(6)
                anchors.top: parent.top
                text: qsTr("all-day")
                color: win.mutedColor
                font.family: win.uiFont
                font.pixelSize: Style.font.caption
            }

            // Drag across the strip to rough out an all-day event; the day
            // view creates timed events only, so it sits this one out.
            MouseArea {
                anchors.fill: parent
                enabled: timeGrid.dayCount > 1

                property int anchorCol: 0
                property real pressX: 0
                property bool creating: false

                onPressed: function(mouse) {
                    anchorCol = timeGrid.columnAt(mouse.x);
                    pressX = mouse.x;
                    creating = false;
                }
                onPositionChanged: function(mouse) {
                    if (!pressed)
                        return;
                    if (Math.abs(mouse.x - pressX) > win.scaledSize(5))
                        creating = true;
                    if (!creating)
                        return;
                    var col = timeGrid.columnAt(mouse.x);
                    timeGrid.shelfPreview = {
                        startCol: Math.min(anchorCol, col),
                        endCol: Math.max(anchorCol, col)
                    };
                }
                onReleased: {
                    var preview = timeGrid.shelfPreview;
                    timeGrid.shelfPreview = null;
                    if (!creating || !preview) {
                        win.clearSelection();
                        return;
                    }
                    creating = false;
                    var start = Cal.addDays(timeGrid.rangeStart, preview.startCol);
                    var end = Cal.addDays(timeGrid.rangeStart, preview.endCol + 1);
                    editor.openForCreate(start.getTime(), end.getTime(), true,
                        shelf.mapToItem(null,
                            timeGrid.gutterWidth + preview.startCol * timeGrid.dayWidth, 0,
                            (preview.endCol - preview.startCol + 1) * timeGrid.dayWidth,
                            shelf.height));
                }
                onCanceled: {
                    creating = false;
                    timeGrid.shelfPreview = null;
                }
            }

            Rectangle {
                visible: timeGrid.activeShelfPreview !== null
                x: timeGrid.gutterWidth + (timeGrid.activeShelfPreview
                    ? timeGrid.activeShelfPreview.startCol * timeGrid.dayWidth : 0)
                width: timeGrid.activeShelfPreview
                    ? (timeGrid.activeShelfPreview.endCol
                        - timeGrid.activeShelfPreview.startCol + 1) * timeGrid.dayWidth : 0
                height: parent.height - win.scaledSize(4)
                radius: win.scaledSize(4)
                color: win.mixColors(win.pageColor, win.accentColor, 0.35)
                border.color: win.accentColor
            }

            Repeater {
                model: timeGrid.shelfSegments

                EventBar {
                    id: shelfBar
                    required property var modelData

                    event: modelData.event
                    selected: win.isEventSelected(event)
                    clipLeft: modelData.clipLeft
                    clipRight: modelData.clipRight

                    x: timeGrid.gutterWidth + modelData.startCol * timeGrid.dayWidth
                        + (modelData.clipLeft ? 0 : win.scaledSize(2))
                    y: modelData.lane * win.scaledSize(20)
                    width: (modelData.endCol - modelData.startCol + 1) * timeGrid.dayWidth
                        - (modelData.clipLeft ? 0 : win.scaledSize(2))
                        - (modelData.clipRight ? 0 : win.scaledSize(2))
                    height: win.scaledSize(18)

                    MouseArea {
                        anchors.fill: parent
                        onClicked: win.selectEvent(shelfBar.event)
                        onDoubleClicked: {
                            win.selectEvent(shelfBar.event);
                            editor.openForEvent(
                                shelfBar.event,
                                shelfBar.mapToItem(null, 0, 0, shelfBar.width, shelfBar.height));
                        }
                    }
                }
            }
        }

        Rectangle {
            width: parent.width
            height: 1
            color: win.lineColor
        }

        // --------------------------------------------------------- hour grid
        Flickable {
            id: flick
            width: parent.width
            height: parent.height - y
            contentHeight: 24 * timeGrid.hourHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            // Wheel scrolling stays native; the lock only keeps the flickable
            // from stealing pointer drags that events and empty slots own.
            interactive: !timeGrid.dragLock

            Item {
                id: gridContent
                width: flick.width
                height: flick.contentHeight

                // Hour lines and labels.
                Repeater {
                    model: 24

                    Item {
                        required property int index
                        y: index * timeGrid.hourHeight
                        width: parent.width
                        height: timeGrid.hourHeight

                        Text {
                            anchors.right: parent.right
                            anchors.rightMargin: parent.width - timeGrid.gutterWidth + win.scaledSize(6)
                            y: -win.scaledSize(7)
                            visible: parent.index > 0
                            text: Cal.formatMinutes(parent.index * 60)
                            color: win.mutedColor
                            font.family: win.uiFont
                            font.pixelSize: Style.font.caption
                        }
                        Rectangle {
                            x: timeGrid.gutterWidth
                            width: parent.width - timeGrid.gutterWidth
                            height: 1
                            color: win.lineColor
                        }
                    }
                }

                // Day separators.
                Repeater {
                    model: timeGrid.dayCount + 1

                    Rectangle {
                        required property int index
                        x: timeGrid.gutterWidth + index * timeGrid.dayWidth
                        width: 1
                        height: parent.height
                        color: win.lineColor
                    }
                }

                // Day columns with their event blocks.
                Repeater {
                    model: timeGrid.dayCount

                    Item {
                        id: dayColumn
                        required property int index
                        readonly property date day: Cal.addDays(timeGrid.rangeStart, index)
                        readonly property double dayStartMs: day.getTime()
                        readonly property double dayEndMs: Cal.addDays(day, 1).getTime()
                        readonly property var laidOut: timeGrid.timedByDay.length > index
                            ? timeGrid.timedByDay[index] : []

                        x: timeGrid.gutterWidth + index * timeGrid.dayWidth
                        width: timeGrid.dayWidth
                        height: parent.height

                        // Empty grid: drag out a new timed event — vertically
                        // for its times, across columns for multi-day spans
                        // (the day view only has the one column). A plain
                        // click clears the selection; double click still
                        // creates a default one-hour event.
                        MouseArea {
                            anchors.fill: parent

                            property double anchorMs: 0
                            property real pressX: 0
                            property real pressY: 0
                            property bool creating: false

                            function msAt(mouse) {
                                var point = mapToItem(gridContent, mouse.x, mouse.y);
                                var day = Cal.addDays(timeGrid.rangeStart,
                                                      timeGrid.columnAt(point.x));
                                return day.getTime()
                                    + timeGrid.snappedMinutes(point.y) * 60000;
                            }

                            onPressed: function(mouse) {
                                anchorMs = msAt(mouse);
                                pressX = mouse.x;
                                pressY = mouse.y;
                                creating = false;
                                timeGrid.dragLock = true;
                            }
                            onPositionChanged: function(mouse) {
                                if (!pressed)
                                    return;
                                if (Math.abs(mouse.x - pressX) > win.scaledSize(4)
                                        || Math.abs(mouse.y - pressY) > win.scaledSize(4))
                                    creating = true;
                                if (!creating)
                                    return;
                                var current = msAt(mouse);
                                timeGrid.createPreview = {
                                    startMs: Math.min(anchorMs, current),
                                    endMs: Math.max(anchorMs, current)
                                };
                            }
                            onReleased: {
                                timeGrid.dragLock = false;
                                var preview = timeGrid.createPreview;
                                timeGrid.createPreview = null;
                                if (!creating || !preview) {
                                    win.clearSelection();
                                    return;
                                }
                                creating = false;
                                if (preview.endMs - preview.startMs < 15 * 60000)
                                    preview.endMs = preview.startMs + 30 * 60000;
                                var top = Cal.dayMinutes(preview.startMs, dayColumn.day);
                                var bottom = Cal.dayMinutes(preview.endMs, dayColumn.day);
                                editor.openForCreate(preview.startMs, preview.endMs, false,
                                    dayColumn.mapToItem(null, 0,
                                        top / 60 * timeGrid.hourHeight,
                                        dayColumn.width,
                                        Math.max(win.scaledSize(20),
                                            (bottom - top) / 60 * timeGrid.hourHeight)));
                            }
                            onCanceled: {
                                timeGrid.dragLock = false;
                                creating = false;
                                timeGrid.createPreview = null;
                            }
                            onDoubleClicked: function(mouse) {
                                var minutes = Math.floor(mouse.y / timeGrid.hourHeight * 60 / 30) * 30;
                                var startMs = dayColumn.dayStartMs + minutes * 60000;
                                // Anchor on the hour slot the event will land in.
                                editor.openForCreate(startMs, startMs + 3600000, false,
                                    dayColumn.mapToItem(null, 0,
                                        minutes / 60 * timeGrid.hourHeight,
                                        dayColumn.width, timeGrid.hourHeight));
                            }
                        }

                        // The rubber-band preview of the event being dragged
                        // out (or the editor's still-open draft), clamped to
                        // this day column like real blocks.
                        Rectangle {
                            visible: timeGrid.activePreview !== null
                                && timeGrid.activePreview.endMs > dayColumn.dayStartMs
                                && timeGrid.activePreview.startMs
                                    < dayColumn.dayEndMs
                            readonly property real topMinutes: timeGrid.activePreview
                                ? Cal.dayMinutes(timeGrid.activePreview.startMs,
                                                 dayColumn.day) : 0
                            readonly property real bottomMinutes: timeGrid.activePreview
                                ? Cal.dayMinutes(timeGrid.activePreview.endMs,
                                                 dayColumn.day) : 0
                            x: win.scaledSize(1)
                            y: topMinutes / 60 * timeGrid.hourHeight
                            width: dayColumn.width - win.scaledSize(3)
                            height: Math.max(win.scaledSize(10),
                                (bottomMinutes - topMinutes) / 60 * timeGrid.hourHeight)
                            radius: win.scaledSize(5)
                            color: win.mixColors(win.pageColor, win.accentColor, 0.35)
                            border.color: win.accentColor
                        }

                        Repeater {
                            model: dayColumn.laidOut.length

                            Rectangle {
                                id: block
                                required property int index
                                readonly property var slot: dayColumn.laidOut[index]
                                readonly property var event: slot.event
                                readonly property color eventColor: win.calendarColor(event.calendarId)
                                readonly property bool selected: win.isEventSelected(event)
                                readonly property bool writable:
                                    !win.calendarReadOnly(event.calendarId)
                                // Positioned by wall clock, so a 23- or
                                // 25-hour day still lines up with the grid.
                                readonly property real topMinutes:
                                    Cal.dayMinutes(event.startMs, dayColumn.day)
                                readonly property real bottomMinutes:
                                    Cal.dayMinutes(event.endMs, dayColumn.day)
                                // Whether this column holds the event's real start/end
                                // edge — only those edges can be resized here.
                                readonly property bool startsHere:
                                    event.startMs >= dayColumn.dayStartMs
                                readonly property bool endsHere:
                                    event.endMs <= dayColumn.dayEndMs

                                // Live drag state: move (minutes + days) and the two
                                // resize handles, all in 15-minute steps.
                                property int dragOffsetMinutes: 0
                                property int dragDayDelta: 0
                                property int resizeStartMinutes: 0
                                property int resizeEndMinutes: 0
                                property bool dragging: false
                                readonly property bool adjusting: dragging
                                    || resizeStartMinutes !== 0 || resizeEndMinutes !== 0

                                readonly property double baseY:
                                    topMinutes / 60 * timeGrid.hourHeight

                                x: slot.column * (dayColumn.width / slot.columns) + win.scaledSize(1)
                                    + dragDayDelta * timeGrid.dayWidth
                                y: baseY + (dragOffsetMinutes + resizeStartMinutes) / 60
                                    * timeGrid.hourHeight
                                width: dayColumn.width / slot.columns - win.scaledSize(3)
                                height: Math.max(win.scaledSize(20),
                                    (bottomMinutes - topMinutes
                                        + resizeEndMinutes - resizeStartMinutes)
                                        / 60 * timeGrid.hourHeight - 1)
                                radius: win.scaledSize(5)
                                color: win.mixColors(win.pageColor, eventColor,
                                    adjusting ? 0.45 : selected ? 0.6 : 0.28)
                                border.color: adjusting || selected ? eventColor : "transparent"

                                Rectangle {
                                    anchors.left: parent.left
                                    anchors.top: parent.top
                                    anchors.bottom: parent.bottom
                                    width: win.scaledSize(3)
                                    radius: parent.radius
                                    color: block.eventColor
                                }

                                // Fill the block's height: the title wraps to
                                // as many lines as fit; leftover space shows
                                // the location, then the times, each as a
                                // one-line subtitle.
                                Column {
                                    id: blockContent
                                    anchors.fill: parent
                                    anchors.leftMargin: win.scaledSize(8)
                                    anchors.rightMargin: win.scaledSize(4)
                                    anchors.topMargin: win.scaledSize(3)
                                    anchors.bottomMargin: win.scaledSize(2)
                                    clip: true

                                    readonly property real subLine: blockSubMetrics.height
                                    readonly property bool showLocation:
                                        block.event.location !== ""
                                        && height - blockTitle.implicitHeight >= subLine
                                    readonly property bool showTime:
                                        height - blockTitle.implicitHeight
                                            - (showLocation ? subLine : 0) >= subLine


                                    Text {
                                        id: blockTitle
                                        width: parent.width
                                        // The title claims its natural height
                                        // first; the subtitles only ever use
                                        // what it leaves over.
                                        height: Math.min(implicitHeight,
                                            Math.max(blockContent.height,
                                                     blockTitleMetrics.height))
                                        text: Cal.displayTitle(block.event)
                                        color: win.inkColor
                                        wrapMode: Text.Wrap
                                        elide: Text.ElideRight
                                        font.family: win.uiFont
                                        font.bold: true
                                        font.pixelSize: Style.font.bodySmall
                                    }
                                    Text {
                                        width: parent.width
                                        height: blockContent.subLine
                                        visible: blockContent.showLocation
                                        text: block.event.location
                                        color: win.mutedColor
                                        elide: Text.ElideRight
                                        font.family: win.uiFont
                                        font.pixelSize: Style.font.caption
                                    }
                                    Text {
                                        width: parent.width
                                        height: blockContent.subLine
                                        visible: blockContent.showTime
                                        text: Cal.formatTime(block.event.startMs
                                                  + (block.dragOffsetMinutes
                                                     + block.dragDayDelta * 1440
                                                     + block.resizeStartMinutes) * 60000)
                                            + " – " + Cal.formatTime(block.event.endMs
                                                  + (block.dragOffsetMinutes
                                                     + block.dragDayDelta * 1440
                                                     + block.resizeEndMinutes) * 60000)
                                        color: win.mutedColor
                                        elide: Text.ElideRight
                                        font.family: win.uiFont
                                        font.pixelSize: Style.font.caption
                                    }
                                }

                                // Move: vertical for time, horizontal across
                                // day columns.
                                MouseArea {
                                    anchors.fill: parent

                                    property point pressPoint: Qt.point(0, 0)

                                    onPressed: function(mouse) {
                                        pressPoint = mapToItem(gridContent, mouse.x, mouse.y);
                                        block.dragOffsetMinutes = 0;
                                        block.dragDayDelta = 0;
                                        timeGrid.dragLock = true;
                                    }
                                    onPositionChanged: function(mouse) {
                                        if (!pressed || !block.writable)
                                            return;
                                        var point = mapToItem(gridContent, mouse.x, mouse.y);
                                        // Past the threshold only: a small wobble
                                        // while clicking must stay a click.
                                        if (Math.abs(point.x - pressPoint.x) <= win.scaledSize(4)
                                                && Math.abs(point.y - pressPoint.y)
                                                    <= win.scaledSize(4))
                                            return;
                                        var minutes =
                                            timeGrid.snapDeltaMinutes(point.y - pressPoint.y);
                                        var days = timeGrid.columnAt(point.x)
                                            - dayColumn.index;
                                        if (minutes !== 0 || days !== 0)
                                            block.dragging = true;
                                        if (block.dragging) {
                                            block.dragOffsetMinutes = minutes;
                                            block.dragDayDelta = days;
                                        }
                                    }
                                    onDoubleClicked: {
                                        win.selectEvent(block.event);
                                        editor.openForEvent(block.event,
                                            block.mapToItem(null, 0, 0,
                                                            block.width, block.height));
                                    }
                                    onReleased: {
                                        timeGrid.dragLock = false;
                                        if (!block.dragging) {
                                            win.selectEvent(block.event);
                                            return;
                                        }
                                        var minutes = block.dragOffsetMinutes;
                                        var days = block.dragDayDelta;
                                        block.dragging = false;
                                        block.dragOffsetMinutes = 0;
                                        block.dragDayDelta = 0;
                                        if (minutes === 0 && days === 0)
                                            return;
                                        var moved = Cal.shiftEventByDays(block.event, days);
                                        moved.startMs += minutes * 60000;
                                        moved.endMs += minutes * 60000;
                                        win.commitEventUpdate(block.event, moved);
                                    }
                                    onCanceled: {
                                        timeGrid.dragLock = false;
                                        block.dragging = false;
                                        block.dragOffsetMinutes = 0;
                                        block.dragDayDelta = 0;
                                    }
                                }

                                // Resize handles on the event's real edges.
                                ResizeHandle {
                                    isStart: true
                                    anchors.top: parent.top
                                    visible: block.startsHere && block.writable
                                }
                                ResizeHandle {
                                    isStart: false
                                    anchors.bottom: parent.bottom
                                    visible: block.endsHere && block.writable
                                }
                            }
                        }
                    }
                }

                // The current time, drawn across today only.
                Repeater {
                    model: timeGrid.dayCount

                    Item {
                        required property int index
                        readonly property date day: Cal.addDays(timeGrid.rangeStart, index)
                        readonly property bool isToday: Cal.sameDay(day, new Date(timeGrid.nowMs))
                        readonly property date now: new Date(timeGrid.nowMs)

                        visible: isToday
                        x: timeGrid.gutterWidth + index * timeGrid.dayWidth
                        y: (now.getHours() * 60 + now.getMinutes()) / 60 * timeGrid.hourHeight
                        width: timeGrid.dayWidth

                        Rectangle {
                            width: win.scaledSize(7)
                            height: width
                            radius: width / 2
                            x: -width / 2
                            y: -height / 2
                            color: win.dangerColor
                        }
                        Rectangle {
                            width: parent.width
                            height: Math.max(1, win.scaledSize(2))
                            y: -height / 2
                            color: win.dangerColor
                        }
                    }
                }
            }
        }
    }
}
