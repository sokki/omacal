// Date and recurrence checks for the QML side, run by bin/test under a few
// timezones. The sources are .pragma library files, so they are evaluated in
// a context with the handful of Qt globals they touch.
"use strict";

const fs = require("fs");
const path = require("path");
const vm = require("vm");

const SOURCE = path.join(__dirname, "..", "src");
const MONTHS = ["January", "February", "March", "April", "May", "June", "July",
                "August", "September", "October", "November", "December"];
const DAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday",
              "Saturday"];

const Qt = {
    locale: () => ({}),
    formatDate: (date, format) => {
        if (format === "dddd") return DAYS[date.getDay()];
        if (format === "MMMM") return MONTHS[date.getMonth()];
        if (format === "MMM") return MONTHS[date.getMonth()].slice(0, 3);
        if (format === "d MMMM") return date.getDate() + " " + MONTHS[date.getMonth()];
        if (format === "d MMM yyyy")
            return date.getDate() + " " + MONTHS[date.getMonth()].slice(0, 3)
                + " " + date.getFullYear();
        return date.toISOString();
    }
};

function load(name) {
    const code = fs.readFileSync(path.join(SOURCE, name), "utf8")
        .replace(/^\.pragma library$/m, "");
    const context = vm.createContext({ Qt, JSON, Math, Date, console });
    vm.runInContext(code, context);
    return context;
}

const Cal = load("Calendar.js");
const Recur = load("Recurrence.js");

let failures = 0;
function check(label, got, want) {
    const ok = String(got) === String(want);
    if (!ok) {
        failures++;
        console.log(`FAIL  ${label}\n        got  ${got}\n        want ${want}`);
    }
    return ok;
}

// --- days that are not 24 hours long ------------------------------------
// Northern-hemisphere transitions fall in these weeks in both test zones.
for (const [label, year, month, day] of [["fall back", 2026, 10, 1],
                                         ["spring forward", 2026, 2, 8]]) {
    const subject = new Date(year, month, day);
    const late = {
        startMs: new Date(year, month, day, 23, 30).getTime(),
        endMs: new Date(year, month, day, 23, 45).getTime(),
        allDay: false
    };
    check(`${label}: a late event stays on its day`,
          Cal.touchesDay(late, subject), true);
    check(`${label}: a late event is not on the next day`,
          Cal.touchesDay(late, Cal.addDays(subject, 1)), false);
    check(`${label}: 23:30 lands on the 23:30 row`,
          Cal.dayMinutes(late.startMs, subject), 23 * 60 + 30);
    check(`${label}: 14:00 lands on the 14:00 row`,
          Cal.dayMinutes(new Date(year, month, day, 14).getTime(), subject), 14 * 60);
    check(`${label}: a day ends at 1440 minutes`,
          Cal.dayMinutes(Cal.addDays(subject, 1).getTime(), subject), 1440);
    // Reopening and saving an event must not walk its wall-clock time.
    check(`${label}: 10:00 rebuilds as 10:00`,
          new Date(Cal.atMinutes(subject, 600)).getHours(), 10);
}

// --- recurrence rules survive a round trip ------------------------------
const start = new Date(2026, 7, 19, 9, 15).getTime();
const rules = [
    "FREQ=DAILY",
    "FREQ=DAILY;BYDAY=MO,TU,WE,TH,FR",
    "FREQ=DAILY;COUNT=10",
    "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE",
    "FREQ=WEEKLY;UNTIL=20261231T235959Z",
    "FREQ=WEEKLY;UNTIL=20261231",
    "FREQ=MONTHLY;BYMONTHDAY=15",
    "FREQ=MONTHLY;BYDAY=-1FR",
    "FREQ=YEARLY;BYMONTH=8",
    "FREQ=YEARLY;BYMONTH=8;BYMONTHDAY=1",
    "FREQ=YEARLY;BYMONTH=3;BYSETPOS=2;BYDAY=SU"
];
for (const rule of rules) {
    const once = Recur.build(Recur.parse(rule, start), start, false);
    const twice = Recur.build(Recur.parse(once, start), start, false);
    // Editing a rule repeatedly must converge, not drift a day per save.
    check(`${rule} is stable`, twice, once);
}
check("a daily rule keeps its weekdays",
      Recur.build(Recur.parse("FREQ=DAILY;BYDAY=MO,TU,WE,TH,FR", start), start, false)
          .includes("BYDAY=MO,TU,WE,TH,FR"), true);
check("a plain daily rule gains no weekdays",
      Recur.build(Recur.parse("FREQ=DAILY", start), start, false), "FREQ=DAILY");
check("a yearly rule keeps its day of month",
      Recur.build(Recur.parse("FREQ=YEARLY;BYMONTH=8;BYMONTHDAY=1", start), start, false)
          .includes("BYMONTHDAY=1"), true);
check("an all-day rule ends on a bare date",
      Recur.build(Recur.parse("FREQ=WEEKLY;UNTIL=20261231", start), start, true)
          .includes("UNTIL=20261231"), true);

const zone = process.env.TZ || "system default";
if (failures > 0) {
    console.log(`\n${failures} failed (TZ=${zone})`);
    process.exit(1);
}
console.log(`PASS   date and recurrence checks (TZ=${zone})`);
