import QtQuick
import "."
import QtQuick.Controls
import QtQuick.Layouts
import "Calendar.js" as Cal
import "Recurrence.js" as Recur

// Apple Calendar's custom repeat sheet: frequency and interval on top, then
// the frequency's own detail (weekday toggles, a day-of-month grid or an
// ordinal weekday, a month grid), and the end condition at the bottom.
Popup {
    id: sheet

    property double startMs: 0
    property bool allDay: false
    // Never null: the delegates below bind to it long before the sheet opens.
    property var recur: Recur.defaultModel(Date.now())

    signal accepted(string rule)

    width: win.scaledSize(400)
    padding: win.scaledSize(14)
    modal: true
    focus: true

    readonly property var unitLabels: recur && recur.interval === 1
        ? [qsTr("day"), qsTr("week"), qsTr("month"), qsTr("year")]
        : [qsTr("days"), qsTr("weeks"), qsTr("months"), qsTr("years")]
    // The week's days in the user's week order, then the whole-day groups;
    // labels come from Recurrence.js so they match its rule descriptions.
    readonly property var posTargets: {
        var list = [];
        for (var i = 0; i < 7; i++) {
            var jsDay = (win.firstDayOfWeek + i) % 7;
            list.push({ label: Cal.localeDayName(jsDay, Locale.LongFormat),
                        value: Recur.WEEKDAYS[jsDay] });
        }
        list.push({ label: Recur.posDayName("DAY"), value: "DAY" });
        list.push({ label: Recur.posDayName("WEEKDAY"), value: "WEEKDAY" });
        list.push({ label: Recur.posDayName("WEEKEND"), value: "WEEKEND" });
        return list;
    }

    function openWith(rule, eventStartMs, isAllDay) {
        startMs = eventStartMs;
        allDay = isAllDay;
        var parsed = rule !== "" ? Recur.parse(rule, eventStartMs) : null;
        recur = parsed !== null ? parsed : Recur.defaultModel(eventStartMs);
        syncControls();
        open();
    }

    // Combo boxes lose their bindings once touched, so every control is
    // re-seated explicitly whenever the sheet opens or the recur changes.
    function syncControls() {
        freqBox.currentIndex = Math.max(0, Recur.FREQUENCIES.indexOf(recur.freq));
        intervalField.text = recur.interval;
        monthlyModeBox.currentIndex = recur.monthlyMode === "weekday" ? 1 : 0;
        yearlyModeBox.currentIndex = recur.yearlyMode === "weekday" ? 1 : 0;
        for (var o = 0; o < Recur.ORDINAL_OPTIONS.length; o++)
            if (Recur.ORDINAL_OPTIONS[o].value === recur.setPos)
                ordinalBox.currentIndex = o;
        for (var p = 0; p < posTargets.length; p++)
            if (posTargets[p].value === recur.posDay)
                posDayBox.currentIndex = p;
    }

    function patch(key, value) {
        var next = JSON.parse(JSON.stringify(recur));
        next[key] = value;
        recur = next;
    }

    function toggleInArray(key, value) {
        var list = recur[key].slice();
        var at = list.indexOf(value);
        if (at === -1)
            list.push(value);
        else if (list.length > 1)     // never leave the rule with nothing selected
            list.splice(at, 1);
        patch(key, list);
    }

    // One cell of the weekday/day-of-month/month toggle grids: filled accent
    // when on, hover feedback when off. The round shape is the weekly circle,
    // which also reads body-sized and bold-when-on.
    component ToggleCell: AbstractButton {
        id: cell

        property bool on: false
        property bool round: false

        background: Rectangle {
            radius: cell.round ? width / 2 : win.scaledSize(5)
            color: cell.on ? win.accentColor
                : cell.hovered ? win.hoverColor : win.panelColor
            border.color: cell.on ? win.accentColor : win.lineColor
        }
        contentItem: Text {
            text: cell.text
            color: cell.on ? win.contrastOn(win.accentColor) : win.inkColor
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            font.family: win.uiFont
            font.bold: cell.round && cell.on
            font.pixelSize: cell.round ? Style.font.body : Style.font.caption
        }
    }

    background: Rectangle {
        color: win.popupColor
        border.color: win.lineColor
        radius: win.scaledSize(10)
    }

    contentItem: ColumnLayout {
        spacing: win.scaledSize(10)

        Text {
            text: qsTr("Custom Repeat")
            color: win.inkColor
            font.family: win.uiFont
            font.bold: true
            font.pixelSize: Style.font.title
        }

        // ---------------------------------------------- frequency & interval
        RowLayout {
            Layout.fillWidth: true
            spacing: win.scaledSize(6)

            Text {
                text: qsTr("Frequency")
                color: win.mutedColor
                font.family: win.uiFont
                font.pixelSize: Style.font.body
                Layout.preferredWidth: win.scaledSize(70)
            }
            EditorCombo {
                id: freqBox
                Layout.fillWidth: true
                model: [qsTr("Daily"), qsTr("Weekly"), qsTr("Monthly"), qsTr("Yearly")]
                onActivated: sheet.patch("freq", Recur.FREQUENCIES[currentIndex])
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: win.scaledSize(6)

            Text {
                text: qsTr("Every")
                color: win.mutedColor
                font.family: win.uiFont
                font.pixelSize: Style.font.body
                Layout.preferredWidth: win.scaledSize(70)
            }
            TextField {
                id: intervalField
                Layout.preferredWidth: win.scaledSize(56)
                horizontalAlignment: TextInput.AlignHCenter
                validator: IntValidator { bottom: 1; top: 999 }
                color: win.inkColor
                font.family: win.uiFont
                font.pixelSize: Style.font.body
                background: Rectangle {
                    radius: win.scaledSize(5)
                    color: win.panelColor
                    border.color: intervalField.activeFocus ? win.accentColor : win.lineColor
                }
                onEditingFinished: {
                    var value = parseInt(text, 10);
                    sheet.patch("interval", isNaN(value) || value < 1 ? 1 : value);
                    text = sheet.recur.interval;
                }
            }
            Text {
                text: sheet.unitLabels[Math.max(0, Recur.FREQUENCIES.indexOf(sheet.recur.freq))]
                color: win.inkColor
                font.family: win.uiFont
                font.pixelSize: Style.font.body
            }
            Item { Layout.fillWidth: true }
        }

        Rectangle { Layout.fillWidth: true; height: 1; color: win.lineColor }

        // -------------------------------------------------------- weekly days
        Flow {
            Layout.fillWidth: true
            visible: sheet.recur.freq === "WEEKLY"
            spacing: win.scaledSize(6)

            Repeater {
                model: 7

                ToggleCell {
                    id: dayToggle
                    required property int index
                    readonly property int jsDay: (win.firstDayOfWeek + index) % 7
                    readonly property string code: Recur.WEEKDAYS[jsDay]

                    round: true
                    on: sheet.recur.byDay.indexOf(code) !== -1
                    text: Cal.localeDayName(jsDay, Locale.NarrowFormat)
                    implicitWidth: win.scaledSize(34)
                    implicitHeight: win.scaledSize(34)
                    onClicked: sheet.toggleInArray("byDay", code)
                }
            }
        }

        // ------------------------------------------------- monthly / yearly
        RowLayout {
            Layout.fillWidth: true
            spacing: win.scaledSize(6)
            visible: sheet.recur.freq === "MONTHLY"

            EditorCombo {
                id: monthlyModeBox
                Layout.preferredWidth: win.scaledSize(96)
                model: [qsTr("Each"), qsTr("On the")]
                onActivated: sheet.patch("monthlyMode", currentIndex === 1 ? "weekday" : "day")
            }
            Item { Layout.fillWidth: true }
        }

        // "Each": the 1–31 day grid.
        Grid {
            Layout.fillWidth: true
            visible: sheet.recur.freq === "MONTHLY" && sheet.recur.monthlyMode === "day"
            columns: 7
            spacing: win.scaledSize(4)

            Repeater {
                model: 31

                ToggleCell {
                    id: monthDay
                    required property int index
                    readonly property int day: index + 1

                    on: sheet.recur.byMonthDay.indexOf(day) !== -1
                    text: day
                    implicitWidth: win.scaledSize(32)
                    implicitHeight: win.scaledSize(26)
                    onClicked: sheet.toggleInArray("byMonthDay", day)
                }
            }
        }

        // "On the": ordinal + weekday, shared by monthly and yearly.
        RowLayout {
            Layout.fillWidth: true
            spacing: win.scaledSize(6)
            visible: (sheet.recur.freq === "MONTHLY" && sheet.recur.monthlyMode === "weekday")
                || (sheet.recur.freq === "YEARLY" && sheet.recur.yearlyMode === "weekday")

            Text {
                text: qsTr("On the")
                color: win.mutedColor
                font.family: win.uiFont
                font.pixelSize: Style.font.body
                visible: sheet.recur.freq === "YEARLY"
            }
            EditorCombo {
                id: ordinalBox
                Layout.fillWidth: true
                model: Recur.ORDINAL_OPTIONS.map(function(o) { return o.label; })
                onActivated: sheet.patch("setPos", Recur.ORDINAL_OPTIONS[currentIndex].value)
            }
            EditorCombo {
                id: posDayBox
                Layout.fillWidth: true
                model: sheet.posTargets.map(function(t) { return t.label; })
                onActivated: sheet.patch("posDay", sheet.posTargets[currentIndex].value)
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: win.scaledSize(6)
            visible: sheet.recur.freq === "YEARLY"

            EditorCombo {
                id: yearlyModeBox
                Layout.preferredWidth: win.scaledSize(96)
                model: [qsTr("Each"), qsTr("On the")]
                onActivated: sheet.patch("yearlyMode", currentIndex === 1 ? "weekday" : "day")
            }
            Item { Layout.fillWidth: true }
        }

        // The month grid — yearly always picks its months.
        Grid {
            Layout.fillWidth: true
            visible: sheet.recur.freq === "YEARLY"
            columns: 6
            spacing: win.scaledSize(4)

            Repeater {
                model: 12

                ToggleCell {
                    id: monthCell
                    required property int index
                    readonly property int month: index + 1

                    on: sheet.recur.byMonth.indexOf(month) !== -1
                    text: Qt.locale().monthName(index, Locale.ShortFormat)
                    implicitWidth: win.scaledSize(50)
                    implicitHeight: win.scaledSize(26)
                    onClicked: sheet.toggleInArray("byMonth", month)
                }
            }
        }

        // ----------------------------------------------------------- footer
        RowLayout {
            Layout.fillWidth: true
            spacing: win.scaledSize(6)

            Text {
                Layout.fillWidth: true
                text: Recur.describe(sheet.recur, sheet.startMs)
                color: win.mutedColor
                elide: Text.ElideRight
                font.family: win.uiFont
                font.pixelSize: Style.font.caption
            }

            PillButton {
                text: qsTr("Cancel")
                onClicked: sheet.close()
            }
            PillButton {
                kind: "accent"
                text: qsTr("OK")
                onClicked: {
                    sheet.accepted(Recur.build(sheet.recur, sheet.startMs, sheet.allDay));
                    sheet.close();
                }
            }
        }
    }

}
