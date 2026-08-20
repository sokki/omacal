// Date arithmetic and layout helpers shared by the calendar views. Dates are
// plain JS Dates in local time; event boundaries travel as epoch milliseconds.
.pragma library

function startOfDay(date) {
    return new Date(date.getFullYear(), date.getMonth(), date.getDate());
}

function addDays(date, days) {
    return new Date(date.getFullYear(), date.getMonth(), date.getDate() + days);
}

function addMonths(date, months) {
    var day = Math.min(date.getDate(), daysInMonth(date.getFullYear(), date.getMonth() + months));
    return new Date(date.getFullYear(), date.getMonth() + months, day);
}

function daysInMonth(year, month) {
    return new Date(year, month + 1, 0).getDate();
}

function sameDay(a, b) {
    return a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth()
        && a.getDate() === b.getDate();
}

function sameMonth(a, b) {
    return a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth();
}

// firstDay follows JS getDay() numbering: 0 = Sunday.
function startOfWeek(date, firstDay) {
    var diff = (date.getDay() - firstDay + 7) % 7;
    return addDays(startOfDay(date), -diff);
}

function monthGridStart(date, firstDay) {
    return startOfWeek(new Date(date.getFullYear(), date.getMonth(), 1), firstDay);
}

// The date window a view needs events for.
function visibleRange(mode, date, firstDay) {
    if (mode === "day") {
        var day = startOfDay(date);
        return { start: day, end: addDays(day, 1) };
    }
    if (mode === "week") {
        var week = startOfWeek(date, firstDay);
        return { start: week, end: addDays(week, 7) };
    }
    // Month (and the year view's warm cache): the fixed six-week grid.
    var start = monthGridStart(date, firstDay);
    return { start: start, end: addDays(start, 42) };
}

// Whether an event overlaps [startMs, endMs). Zero-length events count on
// their start instant. The store caches months beyond the visible window, so
// views prefilter with this before any per-day work.
function overlapsRange(event, startMs, endMs) {
    return event.startMs < endMs && (event.endMs > startMs || event.startMs >= startMs);
}

function eventsInRange(events, startMs, endMs) {
    var inRange = [];
    for (var i = 0; i < events.length; i++)
        if (overlapsRange(events[i], startMs, endMs))
            inRange.push(events[i]);
    return inRange;
}

// A wall-clock time on a given day. Adding minutes to a day's epoch value
// would drift by an hour whenever the clocks change that day.
function atMinutes(day, minutes) {
    return new Date(day.getFullYear(), day.getMonth(), day.getDate(),
                    Math.floor(minutes / 60), minutes % 60).getTime();
}

// Where an instant falls inside a day, in minutes past local midnight,
// clamped to the day. Days are 23 or 25 hours long twice a year, so the
// hour grid positions events by wall clock rather than elapsed time.
function dayMinutes(ms, day) {
    if (ms <= day.getTime())
        return 0;
    if (ms >= addDays(day, 1).getTime())
        return 1440;
    var date = new Date(ms);
    return date.getHours() * 60 + date.getMinutes();
}

// Whether an event touches the given day. All-day ends are exclusive
// midnights, and zero-length timed events still occupy their start day.
function touchesDay(event, day) {
    return overlapsRange(event, day.getTime(), addDays(day, 1).getTime());
}

function daysBetween(a, b) {
    // Both arguments are local midnights; rounding absorbs DST hour shifts.
    return Math.round((b.getTime() - a.getTime()) / 86400000);
}

// Bar events render as horizontal bars spanning their days: every all-day
// event, and any timed event that covers more than one calendar day.
function isBarEvent(event) {
    if (event.allDay)
        return true;
    var firstDay = startOfDay(new Date(event.startMs));
    var lastDay = startOfDay(new Date(Math.max(event.startMs, event.endMs - 1)));
    return daysBetween(firstDay, lastDay) >= 1;
}

// The day columns an event covers inside a dayCount-wide window starting at
// rangeStart (a local midnight), or null when it misses the window entirely.
// Ends are exclusive midnights, so the last day comes from endMs - 1. A
// clipped edge means the event continues beyond the window.
function spanColumns(event, rangeStart, dayCount) {
    var firstDay = startOfDay(new Date(event.startMs));
    var lastDay = startOfDay(new Date(Math.max(event.startMs, event.endMs - 1)));
    var lo = daysBetween(rangeStart, firstDay);
    var hi = daysBetween(rangeStart, lastDay);
    if (hi < 0 || lo >= dayCount)
        return null;
    return {
        startCol: Math.max(0, lo),
        endCol: Math.min(dayCount - 1, hi),
        clipLeft: lo < 0,
        clipRight: hi >= dayCount
    };
}

// Lay the bar events touching [rangeStart, rangeStart + dayCount) out into
// lanes. Returns [{event, startCol, endCol, lane, clipLeft, clipRight}]:
// a clipped edge means the event continues beyond this range, so its bar
// should run flush to the edge, square-cornered, and pick up on the next row.
function layoutBars(events, rangeStart, dayCount) {
    var segments = [];

    for (var i = 0; i < events.length; i++) {
        var event = events[i];
        if (!isBarEvent(event))
            continue;
        var span = spanColumns(event, rangeStart, dayCount);
        if (!span)
            continue;
        span.event = event;
        span.lane = 0;
        segments.push(span);
    }

    // Earlier and longer bars claim the upper lanes, Apple-style.
    segments.sort(function(a, b) {
        return a.startCol - b.startCol
            || (b.endCol - b.startCol) - (a.endCol - a.startCol)
            || a.event.startMs - b.event.startMs;
    });

    var laneEnds = [];
    for (var s = 0; s < segments.length; s++) {
        var lane = -1;
        for (var l = 0; l < laneEnds.length; l++) {
            if (laneEnds[l] < segments[s].startCol) {
                lane = l;
                break;
            }
        }
        if (lane < 0) {
            lane = laneEnds.length;
            laneEnds.push(0);
        }
        laneEnds[lane] = segments[s].endCol;
        segments[s].lane = lane;
    }
    return segments;
}

// A deep copy of an event stamped for store.updateEvent(): the store needs
// the calendar the event currently lives in to detect cross-calendar moves.
function cloneForUpdate(event) {
    var copy = JSON.parse(JSON.stringify(event));
    copy.originalCalendarId = copy.calendarId;
    return copy;
}

// Whether "this and future occurrences" is a meaningful edit scope: from the
// first occurrence it would equal editing the whole series.
function offersFutureScope(event) {
    return event.isFirstOccurrence !== true;
}

// A copy of an event moved by whole days, ready for store.updateEvent().
// Start and end keep their wall-clock time across DST by shifting the date
// part and re-adding the time-of-day offset.
function shiftEventByDays(event, days) {
    function shifted(ms) {
        var day = startOfDay(new Date(ms));
        return addDays(day, days).getTime() + (ms - day.getTime());
    }
    var moved = cloneForUpdate(event);
    moved.startMs = shifted(event.startMs);
    moved.endMs = shifted(event.endMs);
    return moved;
}

// Column layout for one day of timed events: overlapping events split the
// width evenly, Apple Calendar style. Returns [{event, column, columns}] for
// events sorted by start (ties: longer first).
function layoutTimedEvents(events) {
    var sorted = events.slice().sort(function(a, b) {
        return a.startMs - b.startMs || b.endMs - a.endMs;
    });

    var laidOut = [];
    var cluster = [];
    var columnEnds = [];
    var clusterEnd = -Infinity;

    function closeCluster() {
        for (var i = 0; i < cluster.length; i++)
            cluster[i].columns = columnEnds.length;
        cluster = [];
        columnEnds = [];
        clusterEnd = -Infinity;
    }

    for (var i = 0; i < sorted.length; i++) {
        var event = sorted[i];
        // Short events still claim a readable slab of the column.
        var effectiveEnd = Math.max(event.endMs, event.startMs + 15 * 60000);
        if (cluster.length > 0 && event.startMs >= clusterEnd)
            closeCluster();

        var column = -1;
        for (var c = 0; c < columnEnds.length; c++) {
            if (columnEnds[c] <= event.startMs) {
                column = c;
                break;
            }
        }
        if (column < 0) {
            column = columnEnds.length;
            columnEnds.push(0);
        }
        columnEnds[column] = effectiveEnd;
        clusterEnd = Math.max(clusterEnd, effectiveEnd);

        var item = { event: event, column: column, columns: 0 };
        cluster.push(item);
        laidOut.push(item);
    }
    closeCluster();
    return laidOut;
}

// "9", "09:30", "9.15", and "0915" all count as times; returns minutes since
// midnight or -1.
function parseTime(text) {
    var match = /^\s*(\d{1,4})(?:[:.h](\d{1,2}))?\s*$/.exec(text);
    if (!match)
        return -1;
    var hours, minutes;
    if (match[2] !== undefined) {
        if (match[1].length > 2)
            return -1;
        hours = parseInt(match[1], 10);
        minutes = parseInt(match[2], 10);
    } else if (match[1].length <= 2) {
        hours = parseInt(match[1], 10);
        minutes = 0;
    } else {
        var packed = parseInt(match[1], 10);
        hours = Math.floor(packed / 100);
        minutes = packed % 100;
    }
    if (hours > 23 || minutes > 59)
        return -1;
    return hours * 60 + minutes;
}

function formatTime(ms) {
    // 1 = Locale.ShortFormat; the Locale enum itself is not reachable from a
    // .pragma library file.
    return new Date(ms).toLocaleTimeString(Qt.locale(), 1);
}

// Qt.locale() numbers weekdays 1–7 with Sunday as 7; JS uses 0–6 with
// Sunday as 0.
function localeDayName(jsDay, format) {
    return Qt.locale().dayName(jsDay === 0 ? 7 : jsDay, format);
}

function displayTitle(event) {
    return event.summary !== "" ? event.summary : qsTr("New Event");
}

// "Wed, 19 Aug 2026 14:00 – 15:30" — the full span of an event, dropping
// whatever is redundant: single all-day events show one date, same-day timed
// events repeat no date, multi-day ones spell out both ends.
function formatEventRange(event) {
    var dateFormat = "ddd, d MMM yyyy";
    var start = new Date(event.startMs);
    if (event.allDay) {
        var last = new Date(event.endMs - 1);
        if (sameDay(start, last))
            return Qt.formatDate(start, dateFormat);
        return Qt.formatDate(start, dateFormat) + " – " + Qt.formatDate(last, dateFormat);
    }
    var end = new Date(event.endMs);
    if (sameDay(start, end))
        return Qt.formatDate(start, dateFormat) + "  " + formatTime(event.startMs)
            + " – " + formatTime(event.endMs);
    return Qt.formatDate(start, dateFormat) + " " + formatTime(event.startMs)
        + " – " + Qt.formatDate(end, dateFormat) + " " + formatTime(event.endMs);
}

// A description as displayable rich text. Google Calendar stores minimal
// HTML (<b>, <i>, <u>, <a>, <br>, <ol>/<ul>/<li>), which Qt's rich text
// engine renders natively — that passes through. Plain-text descriptions
// get escaped and their newlines become <br>. Bare URLs turn into links in
// both cases (skipped when already inside a tag or attribute).
function descriptionToRichText(text) {
    if (text === undefined || text === null || text === "")
        return "";
    var looksHtml = /<\s*\/?\s*(b|i|u|a|br|p|ol|ul|li|div|span|strong|em)[\s/>]/i.test(text);
    var html = looksHtml
        ? text
        : text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
              .replace(/\n/g, "<br>");
    return html.replace(/(^|>|[^"'>=\w])(https?:\/\/[^\s<>"']+)/g,
        function(match, before, url) {
            return before + '<a href="' + url + '">' + url + "</a>";
        });
}

function formatMinutes(minutes) {
    var date = new Date(2000, 0, 1, Math.floor(minutes / 60), minutes % 60);
    return Qt.formatTime(date, "HH:mm");
}
