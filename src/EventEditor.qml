import QtQuick
import "."
import QtQuick.Controls
import QtQuick.Layouts
import "Calendar.js" as Cal
import "Recurrence.js" as Recur

// The event popover: create and edit in one surface, placed next to whatever
// was clicked. Edits to recurring events touch only the clicked occurrence;
// deleting one asks whether to take the series with it.
Popup {
    id: editor

    parent: Overlay.overlay
    width: win.scaledSize(330)
    padding: win.scaledSize(14)
    modal: false
    focus: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

    property bool creating: true
    property var sourceEvent: ({})
    property string calendarId: ""
    property bool allDay: false
    property date startDate: new Date()
    property date endDate: new Date()
    property int startMinutes: 540
    property int endMinutes: 600
    property var alarms: []
    property bool confirmingDelete: false
    property bool confirmingSave: false
    // The occurrence start as loaded, so series-wide edits know the delta.
    property double originalStartMs: 0
    property string rrule: ""

    // Apple's repeat menu: the quick presets, then Custom… for everything
    // else. A rule that matches no preset is shown by its own description.
    readonly property var repeatPresets: [
        { label: qsTr("Never"), rule: "" },
        { label: qsTr("Every Day"), rule: "FREQ=DAILY" },
        { label: qsTr("Every Week"), rule: "FREQ=WEEKLY" },
        { label: qsTr("Every Month"), rule: "FREQ=MONTHLY" },
        { label: qsTr("Every Year"), rule: "FREQ=YEARLY" }
    ]
    property var repeatOptions: repeatPresets

    // Set once the repeat rule is edited, so saving knows the change cannot
    // be scoped to a single occurrence.
    property bool rruleEdited: false

    function loadRepeat(rule) {
        var normalized = rule === undefined || rule === null ? "" : rule;
        var options = repeatPresets.slice();
        var matched = -1;
        for (var i = 0; i < options.length; i++)
            if (options[i].rule === normalized)
                matched = i;
        if (matched === -1)
            options.push({ label: Recur.describeRule(normalized, occurrenceStartMs()),
                           rule: normalized });
        options.push({ label: qsTr("Custom…"), rule: "custom" });
        repeatOptions = options;
        rrule = normalized;
        repeatBox.currentIndex = matched === -1 ? options.length - 2 : matched;
    }

    // The start the repeat sheet anchors its defaults to.
    function occurrenceStartMs() {
        return allDay ? startDate.getTime()
                      : Cal.atMinutes(startDate, startMinutes);
    }

    // An all-day event writes UNTIL as a bare date, a timed one as a UTC
    // timestamp; toggling all-day has to re-emit the rule in the right form.
    onAllDayChanged: {
        if (rrule !== "" && ruleModel !== null && ruleModel.endMode === "until")
            loadRepeat(Recur.build(ruleModel, occurrenceStartMs(), allDay));
    }

    // The live rule as a model, so the End repeat row can read and rewrite
    // just its ending without disturbing the rest of the rule.
    readonly property var ruleModel: rrule !== ""
        ? Recur.parse(rrule, occurrenceStartMs()) : null

    function patchRule(key, value) {
        if (rrule === "")
            return;
        var next = Recur.parse(rrule, occurrenceStartMs());
        if (next === null)
            return;
        next[key] = value;
        rruleEdited = true;
        loadRepeat(Recur.build(next, occurrenceStartMs(), allDay));
    }

    // Editing a recurring event asks for the scope; "all future" is
    // meaningless on the series' first occurrence.
    readonly property bool seriesEvent: !creating
        && sourceEvent.recurring === true
    readonly property bool offersFutureScope: seriesEvent
        && Cal.offersFutureScope(sourceEvent)
    // Notes show rendered by default; a click switches to raw editing.
    property bool notesEditing: false

    // The Apple Calendar alert presets. Values are minutes before the start
    // (negative = after); `null` is the "no alert" sentinel and "custom"
    // opens the arbitrary-offset popup.
    readonly property var alertPresets: [
        { label: qsTr("None"), minutes: null },
        { label: qsTr("At time of event"), minutes: 0 },
        { label: qsTr("5 minutes before"), minutes: 5 },
        { label: qsTr("10 minutes before"), minutes: 10 },
        { label: qsTr("15 minutes before"), minutes: 15 },
        { label: qsTr("30 minutes before"), minutes: 30 },
        { label: qsTr("1 hour before"), minutes: 60 },
        { label: qsTr("2 hours before"), minutes: 120 },
        { label: qsTr("1 day before"), minutes: 1440 },
        { label: qsTr("2 days before"), minutes: 2880 },
        { label: qsTr("Custom…"), minutes: "custom" }
    ]
    readonly property int maxAlerts: 5

    // A nonzero offset in the largest unit that divides it evenly: the
    // amount, the unit as an index into minutes/hours/days combos, and
    // whether the alert fires after the start.
    function alarmParts(minutes) {
        var amount = Math.abs(minutes);
        var unitIndex = 0;
        if (amount % 1440 === 0) {
            unitIndex = 2;
            amount /= 1440;
        } else if (amount % 60 === 0) {
            unitIndex = 1;
            amount /= 60;
        }
        return { amount: amount, unitIndex: unitIndex, after: minutes < 0 };
    }

    // "45 minutes before", "1 day after", … in the largest unit that fits.
    function formatAlarmLabel(minutes) {
        if (minutes === 0)
            return qsTr("At time of event");
        var parts = alarmParts(minutes);
        var unitNames = [
            parts.amount === 1 ? qsTr("minute") : qsTr("minutes"),
            parts.amount === 1 ? qsTr("hour") : qsTr("hours"),
            parts.amount === 1 ? qsTr("day") : qsTr("days")
        ];
        return qsTr("%1 %2 %3").arg(parts.amount).arg(unitNames[parts.unitIndex])
            .arg(parts.after ? qsTr("after") : qsTr("before"));
    }

    // One row per alert plus a trailing empty one, Apple-style: setting the
    // last row grows the list, choosing "None" removes that alert. The rows
    // are rebuilt wholesale so every combo box re-seats deterministically.
    property var alarmRows: []
    function refreshAlarmRows() {
        var rows = [];
        var count = Math.min(alarms.length + 1, maxAlerts);
        for (var i = 0; i < count; i++) {
            var minutes = i < alarms.length ? alarms[i] : null;
            var options = alertPresets.slice();
            var known = false;
            for (var j = 0; j < options.length; j++)
                known = known || options[j].minutes === minutes;
            if (!known)
                options.splice(options.length - 1, 0,
                               { label: formatAlarmLabel(minutes), minutes: minutes });
            rows.push({ minutes: minutes, options: options });
        }
        alarmRows = rows;
    }

    function loadAlerts(list) {
        alarms = list === undefined ? [] : list.slice();
        refreshAlarmRows();
    }

    function setAlarmAt(row, minutes) {
        var next = alarms.slice();
        var duplicate = next.indexOf(minutes);
        if (minutes === null || (duplicate !== -1 && duplicate !== row)) {
            if (row < next.length)
                next.splice(row, 1);
        } else if (row < next.length) {
            next[row] = minutes;
        } else {
            next.push(minutes);
        }
        alarms = next;
        refreshAlarmRows();
    }

    readonly property var selectedCalendar: win.calendarsById[editor.calendarId] || null
    readonly property bool readOnly: !creating && selectedCalendar !== null
        && selectedCalendar.readOnly

    // Apple Calendar placement: beside the clicked event — to its right when
    // there is room, otherwise to its left — vertically centered on it, and
    // pinned to the top or bottom edge when centering would overflow. A
    // triangle on the popup edge points back at the event. `anchorRect` is
    // the event's rectangle in window coordinates; it is kept so the position
    // re-clamps whenever the popup's own size settles — at open() time the
    // popup still measures the previous event's content.
    property rect anchorRect: Qt.rect(0, 0, 0, 0)
    property bool arrowOnLeft: true
    property real arrowY: 0

    function placeAt(rect) {
        anchorRect = Qt.rect(rect.x, rect.y, rect.width, rect.height);
        reposition();
    }

    function reposition() {
        var margin = win.scaledSize(8);
        var gap = win.scaledSize(10);

        var spaceRight = win.width - (anchorRect.x + anchorRect.width) - gap - margin;
        var spaceLeft = anchorRect.x - gap - margin;
        var toRight = spaceRight >= width || spaceRight >= spaceLeft;
        arrowOnLeft = toRight; // popup right of the event → arrow on its left edge
        var target = toRight ? anchorRect.x + anchorRect.width + gap
                             : anchorRect.x - gap - width;
        x = Math.min(Math.max(margin, target), win.width - width - margin);

        var centered = anchorRect.y + anchorRect.height / 2 - height / 2;
        y = Math.min(Math.max(margin, centered),
                     Math.max(margin, win.height - height - margin));

        // The triangle keeps pointing at the event even when the popup is
        // pinned to an edge; it just never leaves the rounded corners.
        var inset = win.scaledSize(16);
        arrowY = Math.min(Math.max(inset, anchorRect.y + anchorRect.height / 2 - y),
                          height - inset);
    }

    onWidthChanged: if (visible) reposition()
    onHeightChanged: if (visible) reposition()

    background: Item {
        Rectangle {
            id: surface
            anchors.fill: parent
            color: win.mixColors(win.pageColor, win.inkColor, 0.03)
            border.color: win.lineColor
            radius: win.scaledSize(10)
        }

        // The pointer: a rotated square whose inner half hides behind the
        // popup edge, leaving an outlined triangle aimed at the event.
        Item {
            x: editor.arrowOnLeft ? -width + 1 : parent.width - 1
            y: editor.arrowY - height / 2
            width: win.scaledSize(10)
            height: win.scaledSize(20)
            clip: true

            Rectangle {
                width: win.scaledSize(14)
                height: width
                rotation: 45
                x: editor.arrowOnLeft ? parent.width - width / 2 : -width / 2
                anchors.verticalCenter: parent.verticalCenter
                color: surface.color
                border.color: surface.border.color
            }
        }
    }

    // Only calendars that can actually hold the event are offered; the one
    // an existing event already lives on stays listed even when read-only,
    // so the picker still names it.
    readonly property var calendarOptions: {
        var list = [];
        var calendars = store.calendars;
        for (var i = 0; i < calendars.length; i++) {
            if (!calendars[i].readOnly || calendars[i].id === editor.calendarId)
                list.push(calendars[i]);
        }
        return list;
    }

    function firstWritableCalendarId() {
        // The calendar the last event was filed under, remembered across runs.
        var last = win.calendarsById[backend.lastCalendarId];
        if (last !== undefined && !last.readOnly)
            return last.id;
        var calendars = store.calendars;
        for (var i = 0; i < calendars.length; i++)
            if (!calendars[i].readOnly)
                return calendars[i].id;
        return calendars.length > 0 ? calendars[0].id : "";
    }

    function loadTimes(startMs, endMs, isAllDay) {
        allDay = isAllDay;
        var start = new Date(startMs);
        var end = new Date(endMs);
        startDate = Cal.startOfDay(start);
        startMinutes = start.getHours() * 60 + start.getMinutes();
        if (isAllDay) {
            // The exclusive midnight travels as an inclusive last day here.
            endDate = Cal.startOfDay(new Date(endMs - 1));
            endMinutes = startMinutes;
        } else {
            endDate = Cal.startOfDay(end);
            endMinutes = end.getHours() * 60 + end.getMinutes();
        }
    }

    function openForCreate(startMs, endMs, isAllDay, anchor) {
        creating = true;
        confirmingDelete = false;
        sourceEvent = {};
        calendarId = firstWritableCalendarId();
        loadTimes(startMs, endMs, isAllDay);
        summaryField.text = "";
        locationField.text = "";
        notesArea.text = "";
        notesEditing = false;
        allDaySwitch.checked = allDay;
        loadAlerts([]);
        loadRepeat("");
        confirmingSave = false;
        rruleEdited = false;
        originalStartMs = startMs;
        // Views keep drawing the roughed-out span as a ghost while this
        // popover is open.
        win.draftEvent = {
            calendarId: calendarId,
            summary: "",
            allDay: isAllDay,
            startMs: startMs,
            endMs: endMs
        };
        open();
        placeAt(anchor);
        summaryField.forceActiveFocus();
    }

    function openForEvent(event, anchor) {
        creating = false;
        confirmingDelete = false;
        sourceEvent = event;
        calendarId = event.calendarId;
        loadTimes(event.startMs, event.endMs, event.allDay);
        summaryField.text = event.summary;
        locationField.text = event.location;
        notesArea.text = event.description;
        notesEditing = false;
        allDaySwitch.checked = allDay;
        loadAlerts(event.alarms);
        loadRepeat(event.rrule);
        confirmingSave = false;
        rruleEdited = false;
        originalStartMs = event.startMs;
        open();
        placeAt(anchor);
    }

    // Recurring edits need a scope before anything is written; the footer
    // swaps to the choice and calls back into save(scope).
    function requestSave() {
        if (readOnly) {
            close();
            return;
        }
        // A changed recurrence rule lives on the series master; asking which
        // occurrences to touch would be a question with one honest answer.
        if (seriesEvent && !rruleEdited) {
            confirmingSave = true;
            return;
        }
        save(seriesEvent ? "all" : "this");
    }

    function save(scope) {
        if (readOnly) {
            close();
            return;
        }

        var startMs, endMs;
        if (allDay) {
            startMs = startDate.getTime();
            endMs = Cal.addDays(endDate, 1).getTime();
            if (endMs <= startMs)
                endMs = Cal.addDays(startDate, 1).getTime();
        } else {
            startMs = Cal.atMinutes(startDate, startMinutes);
            endMs = Cal.atMinutes(endDate, endMinutes);
            if (endMs <= startMs)
                endMs = startMs + 3600000;
        }

        var event = {
            calendarId: calendarId,
            summary: summaryField.text,
            location: locationField.text,
            description: notesArea.text,
            allDay: allDay,
            startMs: startMs,
            endMs: endMs,
            alarms: alarms,
            rrule: rrule
        };
        backend.lastCalendarId = calendarId;

        if (creating) {
            store.createEvent(event);
        } else {
            event.uid = sourceEvent.uid;
            event.recurring = sourceEvent.recurring;
            event.recurrenceId = sourceEvent.recurrenceId;
            event.originalCalendarId = sourceEvent.calendarId;
            event.originalStartMs = originalStartMs;
            event.scope = scope === undefined ? "this" : scope;
            store.updateEvent(event);
        }
        close();
    }

    function removeEvent(scope) {
        store.removeEvent(sourceEvent.calendarId, sourceEvent.uid,
                          sourceEvent.recurrenceId, scope);
        close();
    }

    onOpened: calendarBox.currentIndex = calendarBox.indexOfValue(editor.calendarId)
    onClosed: win.draftEvent = null
    // A modal child left open while its parent tears down strands the
    // overlay's dim; close the children first, always.
    onAboutToHide: {
        datePicker.close();
        customAlert.close();
        customRepeat.close();
    }


    contentItem: ColumnLayout {
        spacing: win.scaledSize(8)

        Flickable {
            id: summaryFlick
            Layout.fillWidth: true
            // The title wraps and grows with its text; past 4½ lines it
            // scrolls instead, the half line hinting there is more.
            Layout.preferredHeight: Math.min(summaryField.implicitHeight,
                Math.round(summaryMetrics.height * 4.5))
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height
            ScrollBar.vertical: ScrollBar {}

            FontMetrics {
                id: summaryMetrics
                font: summaryField.font
            }

            TextArea.flickable: TextArea {
                id: summaryField
                placeholderText: qsTr("New Event")
                readOnly: editor.readOnly
                wrapMode: TextEdit.Wrap
                color: win.inkColor
                placeholderTextColor: win.faintColor
                font.family: win.uiFont
                font.bold: true
                font.pixelSize: Style.font.heading
                background: null
                padding: 0
                // Return still saves; titles stay newline-free.
                Keys.onReturnPressed: editor.requestSave()
                Keys.onEnterPressed: editor.requestSave()
            }
        }


        TextField {
            id: locationField
            Layout.fillWidth: true
            placeholderText: qsTr("Add Location")
            readOnly: editor.readOnly
            color: win.inkColor
            placeholderTextColor: win.faintColor
            font.family: win.uiFont
            font.pixelSize: Style.font.body
            background: Item {}
            padding: 0
        }

        Rectangle { Layout.fillWidth: true; height: 1; color: win.lineColor }

        // Calendar picker.
        EditorCombo {
            id: calendarBox
            Layout.fillWidth: true
            enabled: !editor.readOnly
                && !(editor.sourceEvent.recurring === true && !editor.creating)
            model: editor.calendarOptions
            textRole: "name"
            valueRole: "id"
            onActivated: function(index) {
                editor.calendarId = editor.calendarOptions[index].id;
            }

            Connections {
                target: editor
                function onCalendarIdChanged() {
                    calendarBox.currentIndex = calendarBox.indexOfValue(editor.calendarId);
                }
            }

            contentItem: Text {
                leftPadding: win.scaledSize(26)
                rightPadding: win.scaledSize(18)
                text: calendarBox.displayText
                color: win.inkColor
                elide: Text.ElideRight
                verticalAlignment: Text.AlignVCenter
                font: calendarBox.font
            }

            Rectangle {
                x: win.scaledSize(8)
                anchors.verticalCenter: parent.verticalCenter
                width: win.scaledSize(10)
                height: width
                radius: width / 2
                color: win.calendarColor(editor.calendarId)
            }
        }

        RowLayout {
            Layout.fillWidth: true

            Text {
                text: qsTr("All-day")
                color: win.inkColor
                font.family: win.uiFont
                font.pixelSize: Style.font.body
            }
            Item { Layout.fillWidth: true }

            // Track-and-knob switch after the omarchy shell's ToggleSwitch:
            // knob at 0.72 of the track height, 120ms throws.
            Item {
                id: allDaySwitch
                property bool checked: false

                readonly property int trackHeight: win.scaledSize(20)
                readonly property int trackWidth: Math.round(trackHeight * 1.9)
                readonly property int knobSize: Math.round(trackHeight * 0.72)
                readonly property int knobInset: Math.max(1, Math.round((trackHeight - knobSize) / 2))

                implicitWidth: trackWidth
                implicitHeight: trackHeight
                opacity: editor.readOnly ? 0.5 : 1.0

                Rectangle {
                    id: allDayTrack
                    anchors.fill: parent
                    radius: height / 2
                    color: allDaySwitch.checked
                        ? win.mixColors(win.pageColor, win.accentColor, 0.35) : win.panelColor
                    border.color: allDaySwitch.checked ? win.accentColor : win.lineColor

                    Behavior on color { ColorAnimation { duration: 120 } }

                    Rectangle {
                        width: allDaySwitch.knobSize
                        height: allDaySwitch.knobSize
                        radius: height / 2
                        x: allDaySwitch.checked
                            ? allDayTrack.width - width - allDaySwitch.knobInset
                            : allDaySwitch.knobInset
                        anchors.verticalCenter: parent.verticalCenter
                        color: allDaySwitch.checked ? win.accentColor : win.mutedColor

                        Behavior on x { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                        Behavior on color { ColorAnimation { duration: 120 } }
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    enabled: !editor.readOnly
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        allDaySwitch.checked = !allDaySwitch.checked;
                        editor.allDay = allDaySwitch.checked;
                    }
                }
            }
        }

        // Start and end rows.
        Repeater {
            model: 2

            RowLayout {
                id: timeRow
                required property int index
                readonly property bool isStart: index === 0
                Layout.fillWidth: true
                spacing: win.scaledSize(6)

                Text {
                    text: timeRow.isStart ? qsTr("Starts") : qsTr("Ends")
                    color: win.mutedColor
                    font.family: win.uiFont
                    font.pixelSize: Style.font.body
                    Layout.preferredWidth: win.scaledSize(58)
                }

                AbstractButton {
                    id: dateButton
                    Layout.fillWidth: true
                    implicitHeight: win.scaledSize(26)
                    enabled: !editor.readOnly
                    onClicked: {
                        datePicker.forStart = timeRow.isStart;
                        datePicker.forUntil = false;
                        datePicker.shownMonth = timeRow.isStart ? editor.startDate
                                                                : editor.endDate;
                        datePicker.open();
                    }
                    background: Rectangle {
                        radius: win.scaledSize(5)
                        color: dateButton.hovered ? win.hoverColor : win.panelColor
                        border.color: win.lineColor
                    }
                    contentItem: Text {
                        text: Qt.formatDate(timeRow.isStart ? editor.startDate : editor.endDate,
                                            "ddd, d MMM yyyy")
                        color: win.inkColor
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        font.family: win.uiFont
                        font.pixelSize: Style.font.body
                    }
                }

                TextField {
                    id: timeField
                    visible: !editor.allDay
                    readOnly: editor.readOnly
                    Layout.preferredWidth: win.scaledSize(64)
                    horizontalAlignment: TextInput.AlignHCenter
                    text: Cal.formatMinutes(timeRow.isStart ? editor.startMinutes
                                                            : editor.endMinutes)
                    color: win.inkColor
                    font.family: win.uiFont
                    font.pixelSize: Style.font.body
                    background: Rectangle {
                        radius: win.scaledSize(5)
                        color: win.panelColor
                        border.color: timeField.activeFocus ? win.accentColor : win.lineColor
                    }
                    // User edits sever the declarative binding, so changes
                    // pushed from the editor re-fill the field by hand.
                    Connections {
                        target: editor
                        function onStartMinutesChanged() {
                            if (timeRow.isStart)
                                timeField.text = Cal.formatMinutes(editor.startMinutes);
                        }
                        function onEndMinutesChanged() {
                            if (!timeRow.isStart)
                                timeField.text = Cal.formatMinutes(editor.endMinutes);
                        }
                    }
                    onEditingFinished: {
                        var minutes = Cal.parseTime(text);
                        if (minutes < 0) {
                            text = Cal.formatMinutes(timeRow.isStart ? editor.startMinutes
                                                                     : editor.endMinutes);
                            return;
                        }
                        if (timeRow.isStart) {
                            // Moving the start keeps the duration, Apple-style.
                            var duration = (editor.endDate.getTime() + editor.endMinutes * 60000)
                                - (editor.startDate.getTime() + editor.startMinutes * 60000);
                            editor.startMinutes = minutes;
                            var newEnd = new Date(editor.startDate.getTime()
                                + minutes * 60000 + Math.max(duration, 0));
                            editor.endDate = Cal.startOfDay(newEnd);
                            editor.endMinutes = newEnd.getHours() * 60 + newEnd.getMinutes();
                        } else {
                            editor.endMinutes = minutes;
                        }
                    }
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: win.scaledSize(6)
            visible: editor.creating || editor.rrule !== "" || editor.seriesEvent

            Text {
                text: qsTr("Repeat")
                color: win.mutedColor
                font.family: win.uiFont
                font.pixelSize: Style.font.body
                Layout.preferredWidth: win.scaledSize(58)
            }

            EditorCombo {
                id: repeatBox
                Layout.fillWidth: true
                // The rule lives on the series, so an occurrence can only
                // change it through the "all events" scope.
                enabled: !editor.readOnly
                model: editor.repeatOptions
                textRole: "label"
                textColor: editor.rrule === "" ? win.mutedColor : win.inkColor
                onActivated: {
                    var chosen = editor.repeatOptions[currentIndex].rule;
                    if (chosen === "custom") {
                        customRepeat.openWith(editor.rrule, editor.occurrenceStartMs(),
                                              editor.allDay);
                        return;
                    }
                    editor.rruleEdited = true;
                    editor.loadRepeat(chosen);
                }
            }
        }

        // End repeat, shown whenever the event repeats at all.
        RowLayout {
            Layout.fillWidth: true
            spacing: win.scaledSize(6)
            visible: editor.rrule !== "" && editor.ruleModel !== null

            Text {
                text: qsTr("End repeat")
                color: win.mutedColor
                font.family: win.uiFont
                font.pixelSize: Style.font.body
                Layout.preferredWidth: win.scaledSize(58)
            }

            EditorCombo {
                id: endRepeatBox
                Layout.fillWidth: true
                enabled: !editor.readOnly
                model: [qsTr("Never"), qsTr("After"), qsTr("On date")]
                textColor: editor.ruleModel && editor.ruleModel.endMode !== "never"
                    ? win.inkColor : win.mutedColor
                onActivated: editor.patchRule("endMode",
                    currentIndex === 1 ? "count" : currentIndex === 2 ? "until" : "never")

                Connections {
                    target: editor
                    function onRuleModelChanged() {
                        if (editor.ruleModel === null)
                            return;
                        endRepeatBox.currentIndex = editor.ruleModel.endMode === "count" ? 1
                            : editor.ruleModel.endMode === "until" ? 2 : 0;
                    }
                }
            }

            TextField {
                id: endCountField
                visible: editor.ruleModel && editor.ruleModel.endMode === "count"
                Layout.preferredWidth: win.scaledSize(48)
                horizontalAlignment: TextInput.AlignHCenter
                readOnly: editor.readOnly
                validator: IntValidator { bottom: 1; top: 999 }
                text: editor.ruleModel ? editor.ruleModel.count : "10"
                color: win.inkColor
                font.family: win.uiFont
                font.pixelSize: Style.font.body
                background: Rectangle {
                    radius: win.scaledSize(5)
                    color: win.panelColor
                    border.color: endCountField.activeFocus ? win.accentColor : win.lineColor
                }
                onEditingFinished: {
                    var value = parseInt(text, 10);
                    editor.patchRule("count", isNaN(value) || value < 1 ? 1 : value);
                }
            }
            Text {
                visible: endCountField.visible
                text: qsTr("times")
                color: win.inkColor
                font.family: win.uiFont
                font.pixelSize: Style.font.body
            }

            AbstractButton {
                id: endUntilButton
                visible: editor.ruleModel && editor.ruleModel.endMode === "until"
                enabled: !editor.readOnly
                implicitHeight: win.scaledSize(26)
                implicitWidth: endUntilLabel.implicitWidth + win.scaledSize(16)
                onClicked: {
                    datePicker.forStart = false;
                    datePicker.forUntil = true;
                    datePicker.shownMonth = new Date(editor.ruleModel.untilMs);
                    datePicker.open();
                }
                background: Rectangle {
                    radius: win.scaledSize(5)
                    color: endUntilButton.hovered ? win.hoverColor : win.panelColor
                    border.color: win.lineColor
                }
                contentItem: Text {
                    id: endUntilLabel
                    text: editor.ruleModel
                        ? Qt.formatDate(new Date(editor.ruleModel.untilMs), "d MMM yyyy") : ""
                    color: win.inkColor
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    font.family: win.uiFont
                    font.pixelSize: Style.font.body
                }
            }
        }

        Repeater {
            model: editor.alarmRows

            RowLayout {
                id: alertRow
                required property var modelData
                required property int index
                Layout.fillWidth: true
                spacing: win.scaledSize(6)

                Text {
                    // Only the first row is labeled; the ones below read as
                    // the additional alerts they are.
                    text: alertRow.index === 0 ? qsTr("Alert") : ""
                    color: win.mutedColor
                    font.family: win.uiFont
                    font.pixelSize: Style.font.body
                    Layout.preferredWidth: win.scaledSize(58)
                }

                EditorCombo {
                    id: alertBox
                    Layout.fillWidth: true
                    enabled: !editor.readOnly
                    model: alertRow.modelData.options
                    textRole: "label"
                    textColor: alertRow.modelData.minutes === null
                        ? win.mutedColor : win.inkColor
                    Component.onCompleted: {
                        for (var i = 0; i < alertRow.modelData.options.length; i++)
                            if (alertRow.modelData.options[i].minutes
                                    === alertRow.modelData.minutes)
                                currentIndex = i;
                    }
                    onActivated: {
                        var chosen = alertRow.modelData.options[currentIndex].minutes;
                        if (chosen === "custom") {
                            customAlert.openForRow(alertRow.index, alertRow.modelData.minutes);
                            return;
                        }
                        editor.setAlarmAt(alertRow.index, chosen);
                    }
                }
            }
        }

        Rectangle {
            Layout.fillWidth: true
            // One line at rest, growing with the notes; past ~20 lines the
            // frame stops and the text scrolls inside it.
            Layout.preferredHeight: Math.min(
                (editor.notesEditing ? notesArea.implicitHeight
                                     : notesRead.implicitHeight) + 2,
                Math.round(notesMetrics.height * 20))
            radius: win.scaledSize(5)
            color: win.panelColor
            border.color: win.lineColor

            FontMetrics {
                id: notesMetrics
                font: notesArea.font
            }

            // Read view: rendered rich text (Google Calendar's minimal HTML
            // included) with links clickable and text selectable for copy.
            // A clean single click on non-link text switches to editing —
            // after a short delay, so drag-selection and double-click word
            // selection never flip the mode.
            Flickable {
                anchors.fill: parent
                anchors.margins: 1
                visible: !editor.notesEditing
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                contentHeight: notesRead.implicitHeight
                interactive: contentHeight > height
                ScrollBar.vertical: ScrollBar {}

                TextArea {
                    id: notesRead
                    width: parent.width
                    readOnly: true
                    selectByMouse: true
                    textFormat: TextEdit.RichText
                    wrapMode: TextEdit.Wrap
                    text: notesArea.text !== ""
                        ? Cal.descriptionToRichText(notesArea.text) : ""
                    placeholderText: qsTr("Add Notes")
                    placeholderTextColor: win.faintColor
                    color: win.inkColor
                    palette.link: win.accentColor
                    font.family: win.uiFont
                    font.pixelSize: Style.font.body
                    leftPadding: win.scaledSize(6)
                    rightPadding: win.scaledSize(6)
                    topPadding: win.scaledSize(4)
                    bottomPadding: win.scaledSize(4)
                    background: null
                    onLinkActivated: function(link) {
                        editPending.stop();
                        Qt.openUrlExternally(link);
                    }

                    HoverHandler {
                        cursorShape: notesRead.hoveredLink !== ""
                            ? Qt.PointingHandCursor : Qt.IBeamCursor
                    }

                    TapHandler {
                        onTapped: function(eventPoint, button) {
                            if (tapCount > 1) {
                                editPending.stop();
                                return;
                            }
                            if (notesRead.linkAt(eventPoint.position.x,
                                                 eventPoint.position.y) !== "")
                                return;
                            editPending.restart();
                        }
                    }

                    Timer {
                        id: editPending
                        interval: 250
                        onTriggered: {
                            if (editor.readOnly || notesRead.selectedText !== "")
                                return;
                            editor.notesEditing = true;
                            notesArea.forceActiveFocus();
                        }
                    }
                }
            }

            // Edit view: the raw description, exactly as stored.
            Flickable {
                anchors.fill: parent
                anchors.margins: 1
                visible: editor.notesEditing
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                interactive: contentHeight > height
                ScrollBar.vertical: ScrollBar {}

                TextArea.flickable: TextArea {
                    id: notesArea
                    placeholderText: qsTr("Add Notes")
                    readOnly: editor.readOnly
                    wrapMode: TextEdit.Wrap
                    color: win.inkColor
                    placeholderTextColor: win.faintColor
                    font.family: win.uiFont
                    font.pixelSize: Style.font.body
                    background: null
                    onActiveFocusChanged: {
                        if (!activeFocus)
                            editor.notesEditing = false;
                    }
                }
            }
        }

        // Footer: delete on the left, cancel/save on the right. Saving or
        // deleting a repeating event swaps the footer for the scope choice.
        RowLayout {
            Layout.fillWidth: true
            spacing: win.scaledSize(6)
            visible: !editor.confirmingDelete && !editor.confirmingSave

            PillButton {
                kind: "danger"
                text: qsTr("Delete")
                visible: !editor.creating && !editor.readOnly
                onClicked: {
                    if (editor.sourceEvent.recurring === true)
                        editor.confirmingDelete = true;
                    else
                        editor.removeEvent("all");
                }
            }

            Item { Layout.fillWidth: true }

            PillButton {
                text: qsTr("Cancel")
                onClicked: editor.close()
            }

            PillButton {
                kind: "accent"
                text: editor.creating ? qsTr("Add") : qsTr("Done")
                visible: !editor.readOnly
                onClicked: editor.requestSave()
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: win.scaledSize(6)
            visible: editor.confirmingDelete

            Text {
                text: qsTr("Delete:")
                color: win.mutedColor
                font.family: win.uiFont
                font.pixelSize: Style.font.body
            }
            Item { Layout.fillWidth: true }

            ScopeRow {
                offersFuture: editor.offersFutureScope
                kind: "danger"
                onChosen: function(scope) { editor.removeEvent(scope); }
            }
        }

        // Save scope for a repeating event: this occurrence, this and all
        // future ones (unless this is the first), or the whole series.
        RowLayout {
            Layout.fillWidth: true
            spacing: win.scaledSize(6)
            visible: editor.confirmingSave

            Text {
                text: qsTr("Change:")
                color: win.mutedColor
                font.family: win.uiFont
                font.pixelSize: Style.font.body
            }
            Item { Layout.fillWidth: true }

            ScopeRow {
                offersFuture: editor.offersFutureScope
                kind: "accent"
                onChosen: function(scope) { editor.save(scope); }
            }
        }
    }

    // Apple's custom repeat sheet; cancelling re-seats the combo that was
    // briefly showing "Custom…".
    CustomRepeat {
        id: customRepeat
        x: (editor.width - width) / 2
        onAccepted: function(rule) {
            editor.rruleEdited = true;
            editor.loadRepeat(rule);
        }
        onClosed: editor.loadRepeat(editor.rrule)
    }

    // Arbitrary alert offsets: an amount, a unit, and before/after the start.
    Popup {
        id: customAlert
        width: win.scaledSize(280)
        padding: win.scaledSize(12)
        x: (editor.width - width) / 2
        modal: true
        // With focus, Escape lands here and closes just this layer instead
        // of falling through to the editor underneath.
        focus: true

        property int forRow: 0
        property bool accepted: false

        function openForRow(row, currentMinutes) {
            forRow = row;
            accepted = false;
            // No alert seeds the sheet with 15 minutes; "at time of event"
            // with 1 minute, since the sheet needs a nonzero amount.
            var minutes = currentMinutes === null ? 15
                : currentMinutes === 0 ? 1 : currentMinutes;
            var parts = editor.alarmParts(minutes);
            whenBox.currentIndex = parts.after ? 1 : 0;
            unitBox.currentIndex = parts.unitIndex;
            amountField.text = parts.amount;
            open();
            amountField.forceActiveFocus();
            amountField.selectAll();
        }

        function accept() {
            var amount = parseInt(amountField.text, 10);
            if (isNaN(amount) || amount < 1) {
                close();
                return;
            }
            var unitMinutes = [1, 60, 1440][unitBox.currentIndex];
            var sign = whenBox.currentIndex === 1 ? -1 : 1;
            accepted = true;
            editor.setAlarmAt(forRow, sign * amount * unitMinutes);
            close();
        }

        // Any non-accepting close (cancel, Escape, click outside) must
        // re-seat the combo that briefly shows "Custom…".
        onClosed: if (!accepted) editor.refreshAlarmRows()

        background: Rectangle {
            color: win.popupColor
            border.color: win.lineColor
            radius: win.scaledSize(8)
        }

        contentItem: ColumnLayout {
            spacing: win.scaledSize(10)

            RowLayout {
                Layout.fillWidth: true
                spacing: win.scaledSize(6)

                TextField {
                    id: amountField
                    Layout.preferredWidth: win.scaledSize(52)
                    horizontalAlignment: TextInput.AlignHCenter
                    validator: IntValidator { bottom: 1; top: 9999 }
                    color: win.inkColor
                    font.family: win.uiFont
                    font.pixelSize: Style.font.body
                    background: Rectangle {
                        radius: win.scaledSize(5)
                        color: win.panelColor
                        border.color: amountField.activeFocus ? win.accentColor : win.lineColor
                    }
                    onAccepted: customAlert.accept()
                }

                EditorCombo {
                    id: unitBox
                    Layout.fillWidth: true
                    model: [qsTr("minutes"), qsTr("hours"), qsTr("days")]
                }

                EditorCombo {
                    id: whenBox
                    Layout.fillWidth: true
                    model: [qsTr("before"), qsTr("after")]
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: win.scaledSize(6)

                Item { Layout.fillWidth: true }

                PillButton {
                    text: qsTr("Cancel")
                    onClicked: customAlert.close()
                }

                PillButton {
                    kind: "accent"
                    text: qsTr("OK")
                    onClicked: customAlert.accept()
                }
            }
        }
    }

    // Small anchored month picker for the start and end date buttons.
    Popup {
        id: datePicker
        width: win.scaledSize(220)
        padding: win.scaledSize(10)
        x: (editor.width - width) / 2
        modal: true
        // With focus, Escape lands here and closes just this layer instead
        // of falling through to the editor underneath.
        focus: true

        property bool forStart: true
        // Third role: the repeat rule's end date.
        property bool forUntil: false
        property date shownMonth: new Date()

        background: Rectangle {
            color: win.popupColor
            border.color: win.lineColor
            radius: win.scaledSize(8)
        }

        contentItem: MiniMonth {
            monthDate: datePicker.shownMonth
            selectedDate: datePicker.forUntil
                ? new Date(editor.ruleModel ? editor.ruleModel.untilMs : 0)
                : datePicker.forStart ? editor.startDate : editor.endDate
            showNav: true
            onMonthShifted: function(step) {
                datePicker.shownMonth = Cal.addMonths(datePicker.shownMonth, step);
            }
            onDayClicked: function(day) {
                if (datePicker.forUntil) {
                    editor.patchRule("untilMs", day.getTime());
                    datePicker.forUntil = false;
                    datePicker.close();
                    return;
                }
                if (datePicker.forStart) {
                    // Keep the length of the event when its first day moves.
                    var lengthDays = Cal.daysBetween(editor.startDate, editor.endDate);
                    editor.startDate = day;
                    editor.endDate = Cal.addDays(day, Math.max(0, lengthDays));
                } else {
                    editor.endDate = day.getTime() >= editor.startDate.getTime()
                        ? day : editor.startDate;
                }
                datePicker.close();
            }
        }
    }
}
