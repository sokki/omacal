// Recurrence rules: parsing, building and describing RFC 5545 RRULEs for the
// repeat editor. The model mirrors the choices Apple Calendar's custom repeat
// sheet offers, so the UI binds to plain properties instead of rule text.
// Parsing is deliberately lossy: parts outside that model (BYWEEKNO,
// BYYEARDAY, BYHOUR, WKST, …) are ignored and are not carried back into a
// rebuilt rule, so a round trip normalizes a rule to what the sheet can show.
.pragma library

// JS getDay() order, for turning a date into a weekday code.
var WEEKDAYS = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"];
// The order rules are emitted in — the ISO week, which makes the weekday and
// weekend groups come out as the contiguous runs readers expect.
var DAY_ORDER = ["MO", "TU", "WE", "TH", "FR", "SA", "SU"];
var FREQUENCIES = ["DAILY", "WEEKLY", "MONTHLY", "YEARLY"];
// Apple offers first…fifth and last; other ordinals are clamped into these.
// The array carries the sheet's combo order, the map serves lookups by value.
var ORDINAL_OPTIONS = [
    { label: "first", value: 1 },
    { label: "second", value: 2 },
    { label: "third", value: 3 },
    { label: "fourth", value: 4 },
    { label: "fifth", value: 5 },
    { label: "last", value: -1 }
];
var ORDINAL_NAMES = {};
for (var _o = 0; _o < ORDINAL_OPTIONS.length; _o++)
    ORDINAL_NAMES[String(ORDINAL_OPTIONS[_o].value)] = ORDINAL_OPTIONS[_o].label;


/*
 * Model
 */

// A fresh model for an event starting at startMs, with every frequency's
// fields preselected from that date so switching frequency in the sheet lands
// on something sensible. Weekly is the starting frequency, as in Apple's
// custom sheet.
function defaultModel(startMs) {
    var start = new Date(startMs);
    var until = new Date(start.getFullYear() + 1, start.getMonth(), start.getDate());
    return {
        freq: "WEEKLY",
        interval: 1,
        byDay: [WEEKDAYS[start.getDay()]],
        monthlyMode: "day",
        byMonthDay: [start.getDate()],
        setPos: nthWeekdayOfMonth(start),
        posDay: WEEKDAYS[start.getDay()],
        byMonth: [start.getMonth() + 1],
        yearlyMode: "day",
        hasByDay: false,
        hasByMonthDay: false,
        endMode: "never",
        count: 10,
        untilMs: until.getTime()
    };
}

// Which "on the <nth> <weekday>" the date falls on, capped at fifth.
function nthWeekdayOfMonth(date) {
    return Math.min(5, Math.max(1, Math.ceil(date.getDate() / 7)));
}


/*
 * Parsing
 */

// An RRULE value ("FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE") as a model. Keys and
// values are read case-insensitively, unknown parts are skipped, and anything
// the rule leaves out keeps its default. Returns null for blank input.
function parse(rrule, startMs) {
    if (rrule === undefined || rrule === null)
        return null;
    var text = String(rrule).trim();
    // Tolerate a leading property name even though callers pass bare values.
    if (/^rrule:/i.test(text))
        text = text.slice(6).trim();
    if (text === "")
        return null;

    var model = defaultModel(startMs);
    var parts = {};
    var chunks = text.split(";");
    for (var i = 0; i < chunks.length; i++) {
        var chunk = chunks[i].trim();
        var equals = chunk.indexOf("=");
        if (equals <= 0)
            continue;
        parts[chunk.slice(0, equals).trim().toUpperCase()] =
            chunk.slice(equals + 1).trim().toUpperCase();
    }

    if (FREQUENCIES.indexOf(parts.FREQ) >= 0)
        model.freq = parts.FREQ;

    var interval = parseInt(parts.INTERVAL, 10);
    if (isFinite(interval) && interval >= 1)
        model.interval = interval;

    // COUNT and UNTIL are mutually exclusive in RFC 5545; if a broken rule
    // carries both, the end date wins.
    var count = parseInt(parts.COUNT, 10);
    if (isFinite(count) && count >= 1) {
        model.endMode = "count";
        model.count = count;
    }
    var untilMs = parseUntil(parts.UNTIL);
    if (untilMs !== null) {
        model.endMode = "until";
        model.untilMs = untilMs;
    }

    var byDay = parseByDay(parts.BYDAY);
    var monthDays = validMonthDays(parseNumbers(parts.BYMONTHDAY));
    var setPos = parseNumbers(parts.BYSETPOS);
    var months = validMonths(parseNumbers(parts.BYMONTH));

    if (model.freq === "WEEKLY" || model.freq === "DAILY") {
        var days = validDays(dayCodesOf(byDay));
        if (days.length > 0) {
            model.byDay = days;
            model.hasByDay = true;
        }
    } else if (model.freq === "MONTHLY") {
        if (monthDays.length > 0) {
            model.monthlyMode = "day";
            model.byMonthDay = monthDays;
        } else if (byDay.length > 0) {
            model.monthlyMode = "weekday";
            applyWeekdayPosition(model, byDay, setPos);
        }
    } else if (model.freq === "YEARLY") {
        if (months.length > 0)
            model.byMonth = months;
        if (byDay.length > 0) {
            model.yearlyMode = "weekday";
            applyWeekdayPosition(model, byDay, setPos);
        } else {
            model.yearlyMode = "day";
            if (monthDays.length > 0) {
                model.byMonthDay = monthDays;
                model.hasByMonthDay = true;
            }
        }
    }

    return model;
}

// "MO,2FR,-1SU" as [{ordinal, day}]; a missing ordinal reads as 0.
function parseByDay(value) {
    var entries = [];
    if (!value)
        return entries;
    var tokens = value.split(",");
    for (var i = 0; i < tokens.length; i++) {
        var match = /^([+-]?\d+)?(SU|MO|TU|WE|TH|FR|SA)$/.exec(tokens[i].trim());
        if (!match)
            continue;
        entries.push({
            ordinal: match[1] === undefined ? 0 : parseInt(match[1], 10),
            day: match[2]
        });
    }
    return entries;
}

function dayCodesOf(entries) {
    var codes = [];
    for (var i = 0; i < entries.length; i++)
        codes.push(entries[i].day);
    return codes;
}

function parseNumbers(value) {
    var numbers = [];
    if (!value)
        return numbers;
    var tokens = value.split(",");
    for (var i = 0; i < tokens.length; i++) {
        var number = parseInt(tokens[i].trim(), 10);
        if (isFinite(number))
            numbers.push(number);
    }
    return numbers;
}

// The "on the <nth> <weekday>" half of a monthly or yearly rule. The ordinal
// comes from BYSETPOS when present, otherwise from a prefixed BYDAY; a rule
// with neither (plain "BYDAY=FR" under MONTHLY, meaning every Friday) keeps
// the model's default ordinal, which is the only lossy case here.
function applyWeekdayPosition(model, entries, setPos) {
    var days = [];
    var ordinal = 0;
    for (var i = 0; i < entries.length; i++) {
        if (days.indexOf(entries[i].day) < 0)
            days.push(entries[i].day);
        if (ordinal === 0 && entries[i].ordinal !== 0)
            ordinal = entries[i].ordinal;
    }
    if (setPos.length > 0)
        ordinal = setPos[0];
    if (ordinal !== 0)
        model.setPos = clampSetPos(ordinal);
    model.posDay = daySetToPosDay(days, model.posDay);
}

// The whole-day groups Apple offers, recognised from the expanded day set.
function daySetToPosDay(days, fallback) {
    if (days.length === 0)
        return fallback;
    var sorted = sortDays(days);
    if (sorted.length === 1)
        return sorted[0];
    if (sorted.length === 7)
        return "DAY";
    var joined = sorted.join(",");
    if (joined === "MO,TU,WE,TH,FR")
        return "WEEKDAY";
    if (joined === "SA,SU")
        return "WEEKEND";
    return sorted[0];
}

// Anything beyond first…fifth and last collapses onto the nearest offer.
function clampSetPos(value) {
    var ordinal = parseInt(value, 10);
    if (!isFinite(ordinal) || ordinal === 0)
        return 1;
    if (ordinal < 0)
        return -1;
    return Math.min(5, ordinal);
}

// UNTIL as epoch milliseconds at local midnight of the last day. The rule's
// date digits name that day directly — for the UTC form the clock time it
// maps to locally is irrelevant, because the sheet works in whole days.
function parseUntil(value) {
    if (!value)
        return null;
    var match = /^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})Z?)?$/.exec(String(value).trim());
    if (!match)
        return null;
    var year = parseInt(match[1], 10);
    var month = parseInt(match[2], 10);
    var day = parseInt(match[3], 10);
    if (month < 1 || month > 12 || day < 1 || day > 31)
        return null;

    // A timestamp is UTC, so it has to be converted before its local date
    // can be read; a bare date is already local. Either way the model keeps
    // the last day, which is what the interface shows and edits.
    if (match[4] !== undefined) {
        var instant = new Date(Date.UTC(year, month - 1, day,
                                        parseInt(match[4], 10),
                                        parseInt(match[5], 10),
                                        parseInt(match[6], 10)));
        return new Date(instant.getFullYear(), instant.getMonth(),
                        instant.getDate()).getTime();
    }
    return new Date(year, month - 1, day).getTime();
}


/*
 * Building
 */

// The model as an RRULE value, without the "RRULE:" prefix. allDay decides
// the UNTIL form: a bare date for all-day events, a UTC timestamp otherwise.
function build(model, startMs, allDay) {
    if (!model || !model.freq)
        return "";
    var freq = String(model.freq).toUpperCase();
    if (FREQUENCIES.indexOf(freq) < 0)
        return "";

    var parts = ["FREQ=" + freq];
    var interval = Math.max(1, Math.floor(Number(model.interval) || 1));
    if (interval > 1)
        parts.push("INTERVAL=" + interval);

    if (freq === "WEEKLY" || freq === "DAILY") {
        var days = validDays(model.byDay || []);
        // A daily rule carries BYDAY only if it had one ("every weekday");
        // otherwise it would silently narrow to a single weekday.
        if (days.length > 0
                && (freq === "WEEKLY" || (model.hasByDay && days.length < 7)))
            parts.push("BYDAY=" + days.join(","));
    } else if (freq === "MONTHLY") {
        if (model.monthlyMode === "weekday") {
            pushWeekdayPosition(parts, model);
        } else {
            var monthDays = validMonthDays(model.byMonthDay || []);
            if (monthDays.length > 0)
                parts.push("BYMONTHDAY=" + monthDays.join(","));
        }
    } else if (freq === "YEARLY") {
        var months = validMonths(model.byMonth || []);
        if (months.length > 0)
            parts.push("BYMONTH=" + months.join(","));
        if (model.yearlyMode === "weekday") {
            pushWeekdayPosition(parts, model);
        } else if (model.hasByMonthDay) {
            var yearDays = validMonthDays(model.byMonthDay || []);
            if (yearDays.length > 0)
                parts.push("BYMONTHDAY=" + yearDays.join(","));
        }
    }

    if (model.endMode === "count") {
        parts.push("COUNT=" + Math.max(1, Math.floor(Number(model.count) || 1)));
    } else if (model.endMode === "until") {
        var until = formatUntil(model.untilMs, allDay);
        if (until !== "")
            parts.push("UNTIL=" + until);
    }
    return parts.join(";");
}

// A single weekday carries its ordinal on BYDAY ("BYDAY=-1FR"); the day
// groups need the explicit BYSETPOS, since the ordinal applies to the set.
function pushWeekdayPosition(parts, model) {
    var days = expandPosDay(model.posDay);
    if (days.length === 0)
        return;
    var setPos = clampSetPos(model.setPos);
    if (days.length === 1) {
        parts.push("BYDAY=" + setPos + days[0]);
        return;
    }
    parts.push("BYDAY=" + days.join(","));
    parts.push("BYSETPOS=" + setPos);
}

function expandPosDay(posDay) {
    var code = String(posDay || "").toUpperCase();
    if (code === "DAY")
        return DAY_ORDER.slice();
    if (code === "WEEKDAY")
        return ["MO", "TU", "WE", "TH", "FR"];
    if (code === "WEEKEND")
        return ["SA", "SU"];
    if (DAY_ORDER.indexOf(code) >= 0)
        return [code];
    return [];
}

// Timed rules end at the close of the chosen local day, so the last
// occurrence on that date is still included; the value travels in UTC, which
// can shift the printed date by the zone offset while naming the same day.
function formatUntil(untilMs, allDay) {
    var ms = Number(untilMs);
    if (!isFinite(ms))
        return "";
    var local = new Date(ms);
    if (allDay) {
        return pad(local.getFullYear(), 4) + pad(local.getMonth() + 1, 2)
            + pad(local.getDate(), 2);
    }
    var close = new Date(local.getFullYear(), local.getMonth(), local.getDate(), 23, 59, 59);
    return pad(close.getUTCFullYear(), 4) + pad(close.getUTCMonth() + 1, 2)
        + pad(close.getUTCDate(), 2) + "T" + pad(close.getUTCHours(), 2)
        + pad(close.getUTCMinutes(), 2) + pad(close.getUTCSeconds(), 2) + "Z";
}


/*
 * Describing
 */

// One line for the repeat row: "Every 2 weeks on Monday, Wednesday",
// "Monthly on the second Tuesday", "Annually on 19 August", with the end
// clause appended when the rule has one.
function describe(model, startMs) {
    if (!model || !model.freq)
        return "";
    var freq = String(model.freq).toUpperCase();
    if (FREQUENCIES.indexOf(freq) < 0)
        return "";

    var start = new Date(startMs);
    var interval = Math.max(1, Math.floor(Number(model.interval) || 1));
    var text;

    if (freq === "DAILY") {
        text = interval === 1 ? "Every day" : "Every " + interval + " days";
    } else if (freq === "WEEKLY") {
        text = interval === 1 ? "Every week" : "Every " + interval + " weeks";
        var days = validDays(model.byDay || []);
        if (days.length > 0)
            text += " on " + joinNames(days, dayName);
    } else if (freq === "MONTHLY") {
        text = interval === 1 ? "Monthly" : "Every " + interval + " months";
        text += " on the " + monthlyDetail(model, start);
    } else {
        text = yearlyText(model, start, interval);
    }

    return text + endClause(model);
}

// parse() then describe(), for callers holding rule text.
function describeRule(rrule, startMs) {
    var model = parse(rrule, startMs);
    return model === null ? "" : describe(model, startMs);
}

function monthlyDetail(model, start) {
    if (model.monthlyMode === "weekday")
        return ordinalName(model.setPos) + " " + posDayName(model.posDay);
    var days = validMonthDays(model.byMonthDay || []);
    if (days.length === 0)
        days = [start.getDate()];
    return joinNames(days, monthDayName);
}

// The month is left unsaid when it is simply the event's own month, so the
// common yearly rule reads "Annually on 19 August" rather than repeating it.
function yearlyText(model, start, interval) {
    var months = validMonths(model.byMonth || []);
    var implied = months.length === 1 && months[0] === start.getMonth() + 1;

    if (model.yearlyMode === "weekday") {
        var base = interval === 1 ? "Annually" : "Every " + interval + " years";
        var text = base + " on the " + ordinalName(model.setPos) + " "
            + posDayName(model.posDay);
        if (months.length > 0)
            text += " of " + joinNames(months, monthName);
        return text;
    }
    if (interval === 1) {
        return implied || months.length === 0
            ? "Annually on " + Qt.formatDate(start, "d MMMM")
            : "Annually in " + joinNames(months, monthName);
    }
    return implied || months.length === 0
        ? "Every " + interval + " years"
        : "Every " + interval + " years in " + joinNames(months, monthName);
}

function endClause(model) {
    if (model.endMode === "count") {
        var count = Math.max(1, Math.floor(Number(model.count) || 1));
        return count === 1 ? ", once" : ", " + count + " times";
    }
    if (model.endMode === "until" && isFinite(Number(model.untilMs)))
        return ", until " + Qt.formatDate(new Date(Number(model.untilMs)), "d MMM yyyy");
    return "";
}

// 2024-01-07 was a Sunday, so the code's getDay() index lands on its weekday
// and the name comes out of the locale rather than a hardcoded table.
function dayName(code) {
    var index = WEEKDAYS.indexOf(code);
    if (index < 0)
        return code;
    return Qt.formatDate(new Date(2024, 0, 7 + index), "dddd");
}

function monthName(month) {
    return Qt.formatDate(new Date(2024, month - 1, 1), "MMMM");
}

function posDayName(posDay) {
    var code = String(posDay || "").toUpperCase();
    if (code === "DAY")
        return "day";
    if (code === "WEEKDAY")
        return "weekday";
    if (code === "WEEKEND")
        return "weekend day";
    return dayName(code);
}

function ordinalName(setPos) {
    return ORDINAL_NAMES[String(clampSetPos(setPos))];
}

// Month days count from the end when negative, the way BYMONTHDAY does.
function monthDayName(day) {
    if (day < 0)
        return day === -1 ? "last day" : ordinalNumber(-day) + "-last day";
    return ordinalNumber(day);
}

function ordinalNumber(value) {
    var tens = value % 100;
    if (tens >= 11 && tens <= 13)
        return value + "th";
    if (value % 10 === 1)
        return value + "st";
    if (value % 10 === 2)
        return value + "nd";
    if (value % 10 === 3)
        return value + "rd";
    return value + "th";
}


/*
 * Shared helpers
 */

function joinNames(values, nameOf) {
    var names = [];
    for (var i = 0; i < values.length; i++)
        names.push(nameOf(values[i]));
    return names.join(", ");
}

function sortDays(days) {
    return days.slice().sort(function(a, b) {
        return DAY_ORDER.indexOf(a) - DAY_ORDER.indexOf(b);
    });
}

// Weekday codes, uppercased, deduped and in emit order; junk is dropped.
function validDays(values) {
    var days = [];
    for (var i = 0; i < values.length; i++) {
        var code = String(values[i]).toUpperCase();
        if (DAY_ORDER.indexOf(code) >= 0 && days.indexOf(code) < 0)
            days.push(code);
    }
    return sortDays(days);
}

// Days of the month, deduped, with the from-the-end ones trailing.
function validMonthDays(values) {
    var days = [];
    for (var i = 0; i < values.length; i++) {
        var day = parseInt(values[i], 10);
        if (!isFinite(day) || day === 0 || day > 31 || day < -31)
            continue;
        if (days.indexOf(day) < 0)
            days.push(day);
    }
    return days.sort(function(a, b) {
        if ((a > 0) !== (b > 0))
            return a > 0 ? -1 : 1;
        return a > 0 ? a - b : b - a;
    });
}

function validMonths(values) {
    var months = [];
    for (var i = 0; i < values.length; i++) {
        var month = parseInt(values[i], 10);
        if (!isFinite(month) || month < 1 || month > 12)
            continue;
        if (months.indexOf(month) < 0)
            months.push(month);
    }
    return months.sort(function(a, b) { return a - b; });
}

function pad(value, width) {
    return String(value).padStart(width, "0");
}
