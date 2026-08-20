import QtQuick
import "."
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Window
import "Calendar.js" as Cal

ApplicationWindow {
    id: win
    width: 1280
    height: 820
    minimumWidth: 760
    minimumHeight: 520
    visible: true
    title: "Omacal"

    readonly property bool darkMode: backend.darkMode
    readonly property color pageColor: backend.themeBackground
    readonly property color inkColor: backend.themeForeground
    readonly property color accentColor: backend.themeAccent
    readonly property color dangerColor: backend.themeDanger

    function mixColors(base, tint, amount) {
        return Qt.rgba(
            base.r + (tint.r - base.r) * amount,
            base.g + (tint.g - base.g) * amount,
            base.b + (tint.b - base.b) * amount, 1);
    }
    readonly property color mutedColor: mixColors(pageColor, inkColor, 0.55)
    readonly property color faintColor: mixColors(pageColor, inkColor, 0.35)
    readonly property color lineColor: mixColors(pageColor, inkColor, 0.12)
    readonly property color panelColor: mixColors(pageColor, inkColor, 0.035)
    readonly property color hoverColor: mixColors(pageColor, inkColor, 0.08)
    readonly property color popupColor: mixColors(pageColor, inkColor, 0.05)

    // The system's regular font family, resolved through fontconfig;
    // main.cpp installs it as the application font.
    readonly property string uiFont: Qt.application.font.family

    // The desktop's text size knob (GNOME's text-scaling-factor, which
    // `omarchy display text size` drives) anchored so its 12px default leaves
    // the app at the sizes it was designed around.
    readonly property real textScale: backend.textScale
    function scaledSize(pixels) {
        return Math.max(1, Math.round(pixels * win.textScale));
    }

    // "day" | "week" | "month" | "year", remembered across runs.
    readonly property string viewMode: backend.viewMode
    property date focusedDate: new Date()
    property bool sidebarOpen: true
    readonly property int firstDayOfWeek: Qt.locale().firstDayOfWeek % 7

    // Today, rechecked so the highlight moves across midnight rather than
    // sticking on the day the window opened.
    property date todayDate: new Date()
    Timer {
        interval: 60000
        running: true
        repeat: true
        onTriggered: {
            var now = new Date();
            if (!Cal.sameDay(now, win.todayDate))
                win.todayDate = now;
        }
    }

    // While the editor popover or the search field own the keyboard, the
    // plain-key shortcuts (arrows, Delete, Return, …) stand down.
    readonly property bool typingContext: editor.opened || searchField.activeFocus

    // The clicked occurrence, keyed so the highlight survives event reloads.
    // A single click selects; the editor opens on double click.
    property string selectedEventKey: ""
    function eventKey(event) {
        return event.calendarId + "\n" + event.uid + "\n" + event.startMs;
    }
    function selectEvent(event) {
        selectedEventKey = eventKey(event);
    }
    function clearSelection() {
        selectedEventKey = "";
    }
    function isEventSelected(event) {
        return selectedEventKey !== "" && selectedEventKey === eventKey(event);
    }

    Shortcut {
        sequence: "Escape"
        enabled: !win.typingContext && win.selectedEventKey !== ""
        onActivated: win.clearSelection()
    }

    // The event being roughed out while the create popover is open; the
    // views draw it as a ghost so the dragged-out span doesn't vanish.
    property var draftEvent: null

    // Edits made without the form — dragging, resizing, the Delete key —
    // ask for the same scope the editor does before touching a series.
    function commitEventUpdate(event, changed) {
        if (event.recurring !== true) {
            store.updateEvent(changed);
            return;
        }
        scopePrompt.ask(event, qsTr("Change"), function(scope) {
            changed.scope = scope;
            changed.originalStartMs = event.startMs;
            store.updateEvent(changed);
        });
    }

    function commitEventDelete(event) {
        if (event.recurring !== true) {
            store.removeEvent(event.calendarId, event.uid, event.recurrenceId, "all");
            clearSelection();
            return;
        }
        scopePrompt.ask(event, qsTr("Delete"), function(scope) {
            store.removeEvent(event.calendarId, event.uid, event.recurrenceId, scope);
            clearSelection();
        });
    }

    function deleteSelectedEvent() {
        var events = store.events;
        for (var i = 0; i < events.length; i++) {
            if (eventKey(events[i]) !== selectedEventKey)
                continue;
            if (calendarReadOnly(events[i].calendarId))
                return;
            commitEventDelete(events[i]);
            return;
        }
    }

    Shortcut {
        sequences: ["Delete", "Backspace"]
        enabled: !win.typingContext && win.selectedEventKey !== ""
        onActivated: win.deleteSelectedEvent()
    }

    // Undo/redo of calendar mutations; while the editor is open its text
    // fields keep their own Ctrl+Z history.
    Shortcut {
        sequence: "Ctrl+Z"
        enabled: !win.typingContext && store.canUndo
        onActivated: store.undo()
    }
    Shortcut {
        sequences: ["Ctrl+Shift+Z", "Ctrl+Y"]
        enabled: !win.typingContext && store.canRedo
        onActivated: store.redo()
    }

    color: pageColor

    // "black" or "white", whichever stays legible on the given color.
    function contrastOn(tint) {
        var luminance = 0.299 * tint.r + 0.587 * tint.g + 0.114 * tint.b;
        return luminance < 0.55 ? "#ffffff" : "#000000";
    }

    // The calendar list keyed by id, with the palette fallback color already
    // resolved. Every event delegate looks its calendar up, so this trades a
    // rebuild per calendarsChanged for O(1) lookups instead of list scans.
    readonly property var calendarsById: {
        var byId = {};
        var calendars = store.calendars;
        for (var i = 0; i < calendars.length; i++) {
            var entry = calendars[i];
            byId[entry.id] = entry.color !== "" ? entry : Object.assign({}, entry, {
                color: backend.themePalette[i % backend.themePalette.length]
            });
        }
        return byId;
    }

    function calendarColor(calendarId) {
        var entry = calendarsById[calendarId];
        return entry ? entry.color : accentColor;
    }

    function calendarReadOnly(calendarId) {
        var entry = calendarsById[calendarId];
        return entry ? entry.readOnly === true : true;
    }

    function setViewMode(mode) {
        backend.viewMode = mode;
    }

    function goToday() {
        focusedDate = new Date();
    }

    function navigate(step) {
        if (viewMode === "day")
            focusedDate = Cal.addDays(focusedDate, step);
        else if (viewMode === "week")
            focusedDate = Cal.addDays(focusedDate, step * 7);
        else if (viewMode === "month")
            focusedDate = Cal.addMonths(focusedDate, step);
        else
            focusedDate = new Date(focusedDate.getFullYear() + step,
                                   focusedDate.getMonth(), 1);
    }

    function showDay(day) {
        focusedDate = day;
        setViewMode("day");
    }

    function updateVisibleRange() {
        var range = Cal.visibleRange(viewMode, focusedDate, firstDayOfWeek);
        store.setVisibleRange(range.start.getTime(), range.end.getTime());
    }
    onViewModeChanged: updateVisibleRange()
    onFocusedDateChanged: updateVisibleRange()

    readonly property string headerTitle: {
        if (viewMode === "year")
            return focusedDate.getFullYear().toString();
        if (viewMode === "day")
            return Qt.formatDate(focusedDate, "dddd, d MMMM yyyy");
        if (viewMode === "week") {
            var start = Cal.startOfWeek(focusedDate, firstDayOfWeek);
            var end = Cal.addDays(start, 6);
            if (start.getMonth() !== end.getMonth())
                return Qt.formatDate(start, "MMM") + " – " + Qt.formatDate(end, "MMM yyyy");
        }
        return Qt.formatDate(focusedDate, "MMMM yyyy");
    }

    Shortcut { sequence: "Ctrl+1"; onActivated: win.setViewMode("day") }
    Shortcut { sequence: "Ctrl+2"; onActivated: win.setViewMode("week") }
    Shortcut { sequence: "Ctrl+3"; onActivated: win.setViewMode("month") }
    Shortcut { sequence: "Ctrl+4"; onActivated: win.setViewMode("year") }
    Shortcut { sequence: "Ctrl+T"; onActivated: win.goToday() }
    Shortcut { sequence: "Ctrl+Left"; onActivated: win.navigate(-1) }
    Shortcut { sequence: "Ctrl+Right"; onActivated: win.navigate(1) }
    Shortcut { sequence: "Ctrl+S"; onActivated: win.sidebarOpen = !win.sidebarOpen }
    Shortcut { sequence: "Ctrl+R"; onActivated: store.refreshAll() }
    Shortcut {
        sequence: "Ctrl+F"
        onActivated: {
            searchField.forceActiveFocus();
            searchField.selectAll();
        }
    }

    // Where a new event will land in the current view, so the popover hangs
    // off the slot itself. The year view has no slots, so it falls back to
    // the middle of the window.
    function newEventAnchor(startMs, endMs, allDay) {
        var view = viewLoader.item;
        var rect = view && view.rectForRange
            ? view.rectForRange(startMs, endMs, allDay) : null;
        return rect ? rect : Qt.rect(win.width / 2, win.height / 2, 0, 0);
    }

    // A one-hour draft on the focused day starting at the given wall-clock
    // hour, anchored to the view slot unless the caller supplies an anchor.
    function createEventAt(startHours, anchorRect) {
        var start = new Date(focusedDate);
        start.setHours(Math.min(23, startHours), 0, 0, 0);
        var startMs = start.getTime();
        editor.openForCreate(startMs, startMs + 3600000, false,
            anchorRect !== undefined ? anchorRect
                                     : newEventAnchor(startMs, startMs + 3600000, false));
    }

    function showSearchResult(result) {
        focusedDate = new Date(result.startMs);
        if (viewMode === "year")
            setViewMode("month");
        selectedEventKey = eventKey(result);
    }

    function activateSearchResult() {
        var results = store.searchResults;
        if (!searchPanel.visible || searchList.currentIndex < 0
                || searchList.currentIndex >= results.length)
            return;
        showSearchResult(results[searchList.currentIndex]);
    }

    // Arrow keys walk the focused day, Apple Calendar style. Disabled while
    // the editor is open so its text fields keep their cursor keys.
    Shortcut {
        sequence: "Left"
        enabled: !win.typingContext
        onActivated: win.focusedDate = Cal.addDays(win.focusedDate, -1)
    }
    Shortcut {
        sequence: "Right"
        enabled: !win.typingContext
        onActivated: win.focusedDate = Cal.addDays(win.focusedDate, 1)
    }
    Shortcut {
        sequence: "Up"
        enabled: !win.typingContext
        onActivated: win.focusedDate = Cal.addDays(win.focusedDate, -7)
    }
    Shortcut {
        sequence: "Down"
        enabled: !win.typingContext
        onActivated: win.focusedDate = Cal.addDays(win.focusedDate, 7)
    }
    Shortcut { sequence: "PgUp"; enabled: !win.typingContext; onActivated: win.navigate(-1) }
    Shortcut { sequence: "PgDown"; enabled: !win.typingContext; onActivated: win.navigate(1) }
    Shortcut { sequence: "Home"; enabled: !win.typingContext; onActivated: win.goToday() }
    Shortcut {
        sequences: ["Return", "Enter"]
        enabled: !win.typingContext
        onActivated: win.createEventAt(9)
    }
    Shortcut {
        sequence: "Ctrl+N"
        onActivated: win.createEventAt(new Date().getHours() + 1)
    }
    Shortcut {
        sequences: ["Meta+F"]
        onActivated: win.visibility = win.visibility === Window.FullScreen
            ? Window.Windowed : Window.FullScreen
    }
    Shortcut { sequence: "Ctrl+Q"; onActivated: win.close() }

    // ------------------------------------------------------------------ header
    header: Rectangle {
        color: win.pageColor
        height: win.scaledSize(60)

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: win.scaledSize(14)
            anchors.rightMargin: win.scaledSize(14)
            spacing: win.scaledSize(10)

            // Sidebar toggle, drawn rather than glyphed so every theme font works.
            AbstractButton {
                id: sidebarButton
                implicitWidth: win.scaledSize(32)
                implicitHeight: win.scaledSize(30)
                onClicked: win.sidebarOpen = !win.sidebarOpen
                background: Rectangle {
                    radius: win.scaledSize(6)
                    color: sidebarButton.hovered ? win.hoverColor : "transparent"
                }
                contentItem: Item {
                    Column {
                        anchors.centerIn: parent
                        spacing: win.scaledSize(3)
                        Repeater {
                            model: 3
                            Rectangle {
                                width: win.scaledSize(14)
                                height: Math.max(1, win.scaledSize(2))
                                radius: height / 2
                                color: win.sidebarOpen ? win.inkColor : win.mutedColor
                            }
                        }
                    }
                }
            }

            AbstractButton {
                id: addButton
                implicitWidth: win.scaledSize(32)
                implicitHeight: win.scaledSize(30)
                onClicked: win.createEventAt(new Date().getHours() + 1,
                                             addButton.mapToItem(null, 0, 0,
                                                                 addButton.width, addButton.height))
                background: Rectangle {
                    radius: win.scaledSize(6)
                    color: addButton.hovered ? win.hoverColor : "transparent"
                }
                contentItem: Text {
                    text: "+"
                    color: win.inkColor
                    font.family: win.uiFont
                    font.pixelSize: win.scaledSize(20)
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }

            Text {
                Layout.leftMargin: win.scaledSize(6)
                text: win.headerTitle
                color: win.inkColor
                font.family: win.uiFont
                font.bold: true
                font.pixelSize: win.scaledSize(20)
                elide: Text.ElideRight
                Layout.fillWidth: true
            }

            // Day / Week / Month / Year segmented switcher.
            Rectangle {
                implicitHeight: win.scaledSize(30)
                implicitWidth: segmentRow.width + win.scaledSize(6)
                radius: win.scaledSize(7)
                color: win.panelColor
                border.color: win.lineColor

                Row {
                    id: segmentRow
                    anchors.centerIn: parent
                    spacing: win.scaledSize(2)

                    Repeater {
                        model: [
                            { label: qsTr("Day"), mode: "day" },
                            { label: qsTr("Week"), mode: "week" },
                            { label: qsTr("Month"), mode: "month" },
                            { label: qsTr("Year"), mode: "year" }
                        ]

                        AbstractButton {
                            id: segment
                            required property var modelData
                            width: win.scaledSize(64)
                            height: win.scaledSize(24)
                            onClicked: win.setViewMode(modelData.mode)
                            background: Rectangle {
                                radius: win.scaledSize(5)
                                color: win.viewMode === segment.modelData.mode
                                    ? win.hoverColor
                                    : segment.hovered ? win.panelColor : "transparent"
                                border.color: win.viewMode === segment.modelData.mode
                                    ? win.lineColor : "transparent"
                            }
                            contentItem: Text {
                                text: segment.modelData.label
                                color: win.viewMode === segment.modelData.mode
                                    ? win.inkColor : win.mutedColor
                                font.family: win.uiFont
                                font.pixelSize: Style.font.body
                                horizontalAlignment: Text.AlignHCenter
                                verticalAlignment: Text.AlignVCenter
                            }
                        }
                    }
                }
            }

            Item { Layout.fillWidth: true }

            // Free-text search over all calendars and all time; results drop
            // down below and navigate on click.
            TextField {
                id: searchField
                Layout.preferredWidth: win.scaledSize(170)
                placeholderText: qsTr("Search")
                color: win.inkColor
                placeholderTextColor: win.faintColor
                font.family: win.uiFont
                font.pixelSize: Style.font.body
                leftPadding: win.scaledSize(8)
                rightPadding: win.scaledSize(8)
                background: Rectangle {
                    implicitHeight: win.scaledSize(28)
                    radius: win.scaledSize(6)
                    color: win.panelColor
                    border.color: searchField.activeFocus ? win.accentColor : win.lineColor
                }
                onTextChanged: {
                    if (text.trim() === "") {
                        searchDebounce.stop();
                        store.clearSearch();
                    } else {
                        searchDebounce.restart();
                    }
                }
                Keys.onEscapePressed: {
                    text = "";
                    store.clearSearch();
                    win.contentItem.forceActiveFocus();
                }
                // Arrow keys walk the result list, Enter jumps to the
                // highlighted hit; the field keeps the typing focus.
                Keys.onDownPressed: {
                    if (searchPanel.visible && searchList.count > 0)
                        searchList.currentIndex =
                            Math.min(searchList.currentIndex + 1, searchList.count - 1);
                }
                Keys.onUpPressed: {
                    if (searchPanel.visible && searchList.count > 0)
                        searchList.currentIndex = Math.max(searchList.currentIndex - 1, 0);
                }
                Keys.onReturnPressed: win.activateSearchResult()
                Keys.onEnterPressed: win.activateSearchResult()

                Timer {
                    id: searchDebounce
                    interval: 250
                    onTriggered: store.search(searchField.text)
                }
            }

            Row {
                spacing: win.scaledSize(2)

                AbstractButton {
                    id: prevButton
                    width: win.scaledSize(28)
                    height: win.scaledSize(28)
                    onClicked: win.navigate(-1)
                    background: Rectangle {
                        radius: win.scaledSize(6)
                        color: prevButton.hovered ? win.hoverColor : "transparent"
                    }
                    contentItem: Text {
                        text: "‹"
                        color: win.inkColor
                        font.family: win.uiFont
                        font.pixelSize: win.scaledSize(18)
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }
                AbstractButton {
                    id: todayButton
                    width: todayLabel.implicitWidth + win.scaledSize(20)
                    height: win.scaledSize(28)
                    onClicked: win.goToday()
                    background: Rectangle {
                        radius: win.scaledSize(6)
                        color: todayButton.hovered ? win.hoverColor : "transparent"
                    }
                    contentItem: Text {
                        id: todayLabel
                        text: qsTr("Today")
                        color: win.inkColor
                        font.family: win.uiFont
                        font.pixelSize: Style.font.subtitle
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }
                AbstractButton {
                    id: nextButton
                    width: win.scaledSize(28)
                    height: win.scaledSize(28)
                    onClicked: win.navigate(1)
                    background: Rectangle {
                        radius: win.scaledSize(6)
                        color: nextButton.hovered ? win.hoverColor : "transparent"
                    }
                    contentItem: Text {
                        text: "›"
                        color: win.inkColor
                        font.family: win.uiFont
                        font.pixelSize: win.scaledSize(18)
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }
            }

            // Manual sync; the arrows spin whenever calendars load or refresh.
            AbstractButton {
                id: syncButton
                implicitWidth: win.scaledSize(28)
                implicitHeight: win.scaledSize(28)
                onClicked: store.refreshAll()
                background: Rectangle {
                    radius: win.scaledSize(6)
                    color: syncButton.hovered ? win.hoverColor : "transparent"
                }
                contentItem: Item {
                    Text {
                        id: syncIcon
                        anchors.centerIn: parent
                        text: "↻"
                        color: store.syncing ? win.accentColor : win.inkColor
                        font.pixelSize: Style.font.heading

                        RotationAnimation on rotation {
                            running: store.syncing
                            from: 0
                            to: 360
                            duration: 900
                            loops: Animation.Infinite
                        }
                        Connections {
                            target: store
                            function onSyncingChanged() {
                                if (!store.syncing)
                                    syncIcon.rotation = 0;
                            }
                        }
                    }
                }
            }
        }

        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: 1
            color: win.lineColor
        }
    }

    // ----------------------------------------------------------------- content
    RowLayout {
        anchors.fill: parent
        spacing: 0

        Rectangle {
            id: sidebar
            Layout.fillHeight: true
            Layout.preferredWidth: win.sidebarOpen ? win.scaledSize(190) : 0
            visible: Layout.preferredWidth > 0
            clip: true
            color: win.panelColor

            Behavior on Layout.preferredWidth {
                NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
            }

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: win.scaledSize(10)
                spacing: win.scaledSize(6)

                ListView {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    model: store.calendars
                    spacing: win.scaledSize(1)

                    // One section per account, the way Apple Calendar groups
                    // its sidebar. Sized on omarchy's shell scale: captions
                    // at 10px on the 12px base.
                    section.property: "group"
                    section.criteria: ViewSection.FullString
                    section.delegate: Item {
                        required property string section
                        width: ListView.view ? ListView.view.width : 0
                        height: sectionLabel.implicitHeight + win.scaledSize(12)

                        Text {
                            id: sectionLabel
                            anchors.left: parent.left
                            anchors.bottom: parent.bottom
                            anchors.bottomMargin: win.scaledSize(3)
                            width: parent.width
                            text: parent.section
                            color: win.mutedColor
                            elide: Text.ElideRight
                            font.family: win.uiFont
                            font.bold: true
                            font.pixelSize: Style.font.caption
                            font.capitalization: Font.AllUppercase
                            font.letterSpacing: 1.2
                        }
                    }

                    delegate: AbstractButton {
                        id: calendarRow
                        required property var modelData
                        width: ListView.view.width
                        height: win.scaledSize(24)
                        onClicked: store.setCalendarSelected(modelData.id, !modelData.selected)

                        // Right-click edits the calendar's name and color.
                        MouseArea {
                            anchors.fill: parent
                            acceptedButtons: Qt.RightButton
                            onClicked: function(mouse) {
                                calendarEditor.openFor(calendarRow.modelData,
                                    calendarRow.mapToItem(null, mouse.x, mouse.y));
                            }
                        }

                        readonly property color rowColor: win.calendarColor(modelData.id)

                        background: Rectangle {
                            radius: win.scaledSize(5)
                            color: calendarRow.hovered ? win.hoverColor : "transparent"
                        }
                        contentItem: Row {
                            spacing: win.scaledSize(7)
                            leftPadding: win.scaledSize(4)

                            Rectangle {
                                anchors.verticalCenter: parent.verticalCenter
                                width: win.scaledSize(12)
                                height: width
                                radius: win.scaledSize(3)
                                color: calendarRow.modelData.selected
                                    ? calendarRow.rowColor : "transparent"
                                border.color: calendarRow.rowColor
                                border.width: Math.max(1, win.scaledSize(1.5))

                                Text {
                                    anchors.centerIn: parent
                                    visible: calendarRow.modelData.selected
                                    text: "✓"
                                    color: win.contrastOn(calendarRow.rowColor)
                                    font.pixelSize: win.scaledSize(8)
                                    font.bold: true
                                }
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                width: parent.width - win.scaledSize(27)
                                text: calendarRow.modelData.name
                                color: win.inkColor
                                elide: Text.ElideRight
                                font.family: win.uiFont
                                font.pixelSize: Style.font.body
                            }
                        }
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    height: 1
                    color: win.lineColor
                }

                MiniMonth {
                    Layout.fillWidth: true
                    monthDate: win.focusedDate
                    selectedDate: win.focusedDate
                    showNav: true
                    onDayClicked: function(day) { win.focusedDate = day; }
                    onMonthShifted: function(step) {
                        win.focusedDate = Cal.addMonths(win.focusedDate, step);
                    }
                }
            }

            Rectangle {
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                width: 1
                color: win.lineColor
            }
        }

        Loader {
            id: viewLoader
            Layout.fillWidth: true
            Layout.fillHeight: true
            sourceComponent: win.viewMode === "month" ? monthComponent
                : win.viewMode === "year" ? yearComponent
                : timeGridComponent
        }
    }

    Component {
        id: monthComponent
        MonthView {}
    }
    Component {
        id: timeGridComponent
        TimeGridView {
            dayCount: win.viewMode === "day" ? 1 : 7
        }
    }
    Component {
        id: yearComponent
        YearView {}
    }

    EventEditor {
        id: editor
    }

    CalendarEditor {
        id: calendarEditor
    }

    // Scope choice for direct manipulations of a repeating event.
    Popup {
        id: scopePrompt

        property string verb: ""
        property string summary: ""
        property bool offersFuture: false
        property var pending: null

        function ask(event, actionVerb, apply) {
            verb = actionVerb;
            summary = Cal.displayTitle(event);
            offersFuture = Cal.offersFutureScope(event);
            pending = apply;
            open();
        }

        parent: Overlay.overlay
        anchors.centerIn: Overlay.overlay
        width: win.scaledSize(360)
        padding: win.scaledSize(16)
        modal: true
        focus: true
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

        background: Rectangle {
            color: win.popupColor
            border.color: win.lineColor
            radius: win.scaledSize(10)
        }

        contentItem: ColumnLayout {
            spacing: win.scaledSize(12)

            Text {
                Layout.fillWidth: true
                text: qsTr("“%1” is a repeating event.").arg(scopePrompt.summary)
                color: win.inkColor
                wrapMode: Text.Wrap
                font.family: win.uiFont
                font.bold: true
                font.pixelSize: Style.font.subtitle
            }
            Text {
                Layout.fillWidth: true
                text: scopePrompt.verb === qsTr("Delete")
                    ? qsTr("Delete this occurrence, or the whole series?")
                    : qsTr("Apply the change to this occurrence, or the whole series?")
                color: win.mutedColor
                wrapMode: Text.Wrap
                font.family: win.uiFont
                font.pixelSize: Style.font.body
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: win.scaledSize(6)

                PillButton {
                    text: qsTr("Cancel")
                    onClicked: scopePrompt.close()
                }
                Item { Layout.fillWidth: true }

                ScopeRow {
                    offersFuture: scopePrompt.offersFuture
                    kind: scopePrompt.verb === qsTr("Delete") ? "danger" : "accent"
                    onChosen: function(scope) {
                        var apply = scopePrompt.pending;
                        scopePrompt.pending = null;
                        scopePrompt.close();
                        if (apply)
                            apply(scope);
                    }
                }
            }
        }
    }

    // Search results, dropped down under the header's search field. Stays
    // put while results are clicked; Escape or clearing the field closes it.
    Rectangle {
        id: searchPanel
        visible: searchField.text.trim() !== ""
        anchors.top: parent.top
        anchors.topMargin: win.scaledSize(4)
        anchors.right: parent.right
        anchors.rightMargin: win.scaledSize(14)
        width: win.scaledSize(360)
        height: Math.min(searchList.contentHeight, win.scaledSize(420))
            + win.scaledSize(12)
        z: 50
        radius: win.scaledSize(8)
        color: win.popupColor
        border.color: win.lineColor

        ListView {
            id: searchList
            anchors.fill: parent
            anchors.margins: win.scaledSize(6)
            clip: true
            model: store.searchResults
            boundsBehavior: Flickable.StopAtBounds
            // The top hit starts highlighted, so Enter jumps straight to it.
            currentIndex: 0
            onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)

            Connections {
                target: store
                function onSearchResultsChanged() { searchList.currentIndex = 0; }
            }

            Text {
                anchors.centerIn: parent
                visible: searchList.count === 0
                text: qsTr("No results")
                color: win.mutedColor
                font.family: win.uiFont
                font.pixelSize: Style.font.body
            }

            delegate: AbstractButton {
                id: searchRow
                required property var modelData
                required property int index
                width: ListView.view.width
                height: win.scaledSize(40)
                onClicked: {
                    searchList.currentIndex = searchRow.index;
                    win.showSearchResult(modelData);
                }

                background: Rectangle {
                    radius: win.scaledSize(5)
                    color: searchRow.ListView.isCurrentItem
                        ? win.mixColors(win.pageColor, win.accentColor, 0.2)
                        : searchRow.hovered ? win.hoverColor : "transparent"
                }
                contentItem: Item {
                    Rectangle {
                        id: searchDot
                        anchors.left: parent.left
                        anchors.leftMargin: win.scaledSize(6)
                        anchors.verticalCenter: parent.verticalCenter
                        width: win.scaledSize(8)
                        height: width
                        radius: width / 2
                        color: win.calendarColor(searchRow.modelData.calendarId)
                    }
                    Column {
                        anchors.left: searchDot.right
                        anchors.leftMargin: win.scaledSize(8)
                        anchors.right: parent.right
                        anchors.rightMargin: win.scaledSize(6)
                        anchors.verticalCenter: parent.verticalCenter

                        Text {
                            width: parent.width
                            text: (searchRow.modelData.recurring ? "↻ " : "")
                                + Cal.displayTitle(searchRow.modelData)
                            color: win.inkColor
                            elide: Text.ElideRight
                            font.family: win.uiFont
                            font.pixelSize: Style.font.body
                        }
                        Text {
                            width: parent.width
                            text: Cal.formatEventRange(searchRow.modelData)
                                + (searchRow.modelData.location !== ""
                                    ? "  ·  " + searchRow.modelData.location : "")
                            color: win.mutedColor
                            elide: Text.ElideRight
                            font.family: win.uiFont
                            font.pixelSize: Style.font.caption
                        }
                    }
                }
            }
        }
    }

    // Surfaced EDS failures land in an unobtrusive dismissable strip.
    Rectangle {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: win.scaledSize(16)
        width: Math.min(errorLabel.implicitWidth + win.scaledSize(40), win.width - win.scaledSize(40))
        height: visible ? win.scaledSize(34) : 0
        radius: win.scaledSize(8)
        color: win.mixColors(win.pageColor, win.dangerColor, 0.25)
        border.color: win.dangerColor
        visible: store.lastError !== "" && errorTimer.running

        Text {
            id: errorLabel
            anchors.centerIn: parent
            width: Math.min(implicitWidth, parent.width - win.scaledSize(20))
            text: store.lastError
            color: win.inkColor
            elide: Text.ElideRight
            font.family: win.uiFont
            font.pixelSize: Style.font.body
        }
        Connections {
            target: store
            function onLastErrorChanged() { errorTimer.restart(); }
        }
        Timer {
            id: errorTimer
            interval: 6000
        }
    }

    // Remember the last windowed geometry rather than whatever the window
    // happens to measure at teardown: a maximized window reports screen-sized
    // dimensions, and the close sequence hides the window before destruction,
    // so neither the live geometry nor the final visibility can be trusted.
    property rect normalGeometry: Qt.rect(x, y, width, height)
    property bool wasMaximized: false

    function trackNormalGeometry() {
        if (visibility === Window.Windowed)
            normalGeometry = Qt.rect(x, y, width, height);
    }

    onXChanged: trackNormalGeometry()
    onYChanged: trackNormalGeometry()
    onWidthChanged: trackNormalGeometry()
    onHeightChanged: trackNormalGeometry()

    onVisibilityChanged: {
        if (win.visibility === Window.Maximized || win.visibility === Window.FullScreen)
            wasMaximized = true;
        else if (win.visibility === Window.Windowed)
            wasMaximized = false;
    }

    Component.onDestruction: backend.saveWindowGeometry(
        normalGeometry.x, normalGeometry.y,
        normalGeometry.width, normalGeometry.height, wasMaximized)

    // Restore the remembered geometry once, before first paint.
    Component.onCompleted: {
        updateVisibleRange();

        var geometry = backend.windowGeometry();
        if (geometry.valid) {
            x = geometry.x;
            y = geometry.y;
            width = geometry.width;
            height = geometry.height;
            if (geometry.maximized)
                showMaximized();
        } else {
            width = Math.round(1280 * backend.textScale);
            height = Math.round(820 * backend.textScale);
        }
    }
}
