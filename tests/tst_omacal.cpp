#include <libecal/libecal.h>

#include <QtTest>

#include "backend.h"
#include "calendarstore.h"

namespace {
QString writeColors(QTemporaryDir &directory, const QByteArray &content) {
    const QString path = directory.path() + QStringLiteral("/colors.toml");
    QFile file(path);
    file.open(QIODevice::WriteOnly);
    file.write(content);
    file.close();
    return path;
}
}

class OmacalTest : public QObject {
    Q_OBJECT

private slots:
    void initTestCase() {
        QVERIFY(m_settingsDirectory.isValid());
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope,
                           m_settingsDirectory.path());
    }

    void parsesColorsFile() {
        QTemporaryDir directory;
        const QString path = writeColors(directory,
            "mode = \"dark\"\n"
            "# a comment\n"
            "accent = \"#7d82d9\"\n"
            "background = '#060B1E'\n"
            "broken line without equals\n"
            "foreground=\"#ffcead\"\n");

        const QHash<QString, QString> colors = Backend::colorsFromFile(path);
        QCOMPARE(colors.value(QStringLiteral("mode")), QStringLiteral("dark"));
        QCOMPARE(colors.value(QStringLiteral("accent")), QStringLiteral("#7d82d9"));
        QCOMPARE(colors.value(QStringLiteral("background")), QStringLiteral("#060B1E"));
        QCOMPARE(colors.value(QStringLiteral("foreground")), QStringLiteral("#ffcead"));
        QVERIFY(!colors.contains(QStringLiteral("broken line without equals")));
    }

    void missingColorsFileIsEmpty() {
        QCOMPARE(Backend::colorsFromFile(QStringLiteral("/nonexistent/colors.toml")).size(), 0);
    }

    void rememberedGeometryRoundTrips() {
        Backend backend;
        backend.saveWindowGeometry(12, -34, 1280, 820, true);

        const QVariantMap geometry = backend.windowGeometry();
        QVERIFY(geometry.value(QStringLiteral("valid")).toBool());
        QCOMPARE(geometry.value(QStringLiteral("x")).toInt(), 12);
        QCOMPARE(geometry.value(QStringLiteral("y")).toInt(), -34);
        QCOMPARE(geometry.value(QStringLiteral("width")).toInt(), 1280);
        QCOMPARE(geometry.value(QStringLiteral("height")).toInt(), 820);
        QVERIFY(geometry.value(QStringLiteral("maximized")).toBool());
    }

    void viewModePersists() {
        {
            Backend backend;
            backend.setViewMode(QStringLiteral("week"));
        }
        Backend backend;
        QCOMPARE(backend.viewMode(), QStringLiteral("week"));
    }

    void timedEventRoundTrips() {
        QVariantMap event;
        event.insert(QStringLiteral("summary"), QStringLiteral("Standup"));
        event.insert(QStringLiteral("location"), QStringLiteral("Room 3"));
        event.insert(QStringLiteral("description"), QStringLiteral("Daily sync"));
        event.insert(QStringLiteral("allDay"), false);
        const QDateTime start(QDate(2026, 8, 19), QTime(9, 30));
        event.insert(QStringLiteral("startMs"), double(start.toMSecsSinceEpoch()));
        event.insert(QStringLiteral("endMs"), double(start.addSecs(1800).toMSecsSinceEpoch()));

        ICalComponent *component = CalendarStore::componentFromEvent(event);
        QVERIFY(component);
        const QVariantMap parsed = CalendarStore::eventFromComponent(component);
        g_object_unref(component);

        QCOMPARE(parsed.value(QStringLiteral("summary")).toString(), QStringLiteral("Standup"));
        QCOMPARE(parsed.value(QStringLiteral("location")).toString(), QStringLiteral("Room 3"));
        QCOMPARE(parsed.value(QStringLiteral("description")).toString(),
                 QStringLiteral("Daily sync"));
        QCOMPARE(parsed.value(QStringLiteral("allDay")).toBool(), false);
        QCOMPARE(qint64(parsed.value(QStringLiteral("startMs")).toDouble()),
                 start.toMSecsSinceEpoch());
        QCOMPARE(qint64(parsed.value(QStringLiteral("endMs")).toDouble()),
                 start.addSecs(1800).toMSecsSinceEpoch());
        QCOMPARE(parsed.value(QStringLiteral("recurring")).toBool(), false);
        QVERIFY(parsed.value(QStringLiteral("alarms")).toList().isEmpty());
    }

    void alertsRoundTrip() {
        QVariantMap event;
        event.insert(QStringLiteral("summary"), QStringLiteral("Standup"));
        event.insert(QStringLiteral("allDay"), false);
        event.insert(QStringLiteral("startMs"), double(0));
        event.insert(QStringLiteral("endMs"), double(3600000));

        const auto roundTrip = [&event](const QVariantList &alarms) {
            event.insert(QStringLiteral("alarms"), alarms);
            ICalComponent *component = CalendarStore::componentFromEvent(event);
            const QVariantMap parsed = CalendarStore::eventFromComponent(component);
            g_object_unref(component);
            return parsed.value(QStringLiteral("alarms")).toList();
        };

        QCOMPARE(roundTrip({10}), QVariantList({10}));
        QCOMPARE(roundTrip({0, 30, 1440}), QVariantList({0, 30, 1440}));
        QCOMPARE(roundTrip({}), QVariantList());
        // Negative minutes mean "after the start" and survive the trip.
        QCOMPARE(roundTrip({-30, 45, -1440}), QVariantList({-30, 45, -1440}));
        // Duplicates never reach the component.
        QCOMPARE(roundTrip({10, 10, 60}), QVariantList({10, 60}));
    }

    void editingReplacesTheAlerts() {
        QVariantMap event;
        event.insert(QStringLiteral("summary"), QStringLiteral("Standup"));
        event.insert(QStringLiteral("allDay"), false);
        event.insert(QStringLiteral("startMs"), double(0));
        event.insert(QStringLiteral("endMs"), double(3600000));
        event.insert(QStringLiteral("alarms"), QVariantList({30}));

        ICalComponent *component = CalendarStore::componentFromEvent(event);
        event.insert(QStringLiteral("alarms"), QVariantList({5, 1440}));
        CalendarStore::applyEventToComponent(component, event);

        const QVariantMap parsed = CalendarStore::eventFromComponent(component);
        QCOMPARE(parsed.value(QStringLiteral("alarms")).toList(), QVariantList({5, 1440}));
        QCOMPARE(i_cal_component_count_components(component, I_CAL_VALARM_COMPONENT), 2);

        event.insert(QStringLiteral("alarms"), QVariantList());
        CalendarStore::applyEventToComponent(component, event);
        QCOMPARE(i_cal_component_count_components(component, I_CAL_VALARM_COMPONENT), 0);
        g_object_unref(component);
    }

    void allDayEventRoundTrips() {
        QVariantMap event;
        event.insert(QStringLiteral("summary"), QStringLiteral("Conference"));
        event.insert(QStringLiteral("allDay"), true);
        const QDate day(2026, 8, 19);
        event.insert(QStringLiteral("startMs"),
                     double(day.startOfDay().toMSecsSinceEpoch()));
        event.insert(QStringLiteral("endMs"),
                     double(day.addDays(2).startOfDay().toMSecsSinceEpoch()));

        ICalComponent *component = CalendarStore::componentFromEvent(event);
        QVERIFY(component);
        const QVariantMap parsed = CalendarStore::eventFromComponent(component);
        g_object_unref(component);

        QCOMPARE(parsed.value(QStringLiteral("allDay")).toBool(), true);
        QCOMPARE(qint64(parsed.value(QStringLiteral("startMs")).toDouble()),
                 day.startOfDay().toMSecsSinceEpoch());
        QCOMPARE(qint64(parsed.value(QStringLiteral("endMs")).toDouble()),
                 day.addDays(2).startOfDay().toMSecsSinceEpoch());
    }

    void parsesDayScaleAlarms() {
        // Day-scale triggers reach us in several equivalent spellings; all
        // must read back as minutes, not as "at time of event".
        const QList<QPair<QByteArray, int>> triggers = {
            {"-P1D", 1440}, {"-PT1440M", 1440}, {"-P2D", 2880},
            {"-PT24H", 1440}, {"-PT30M", 30}, {"PT0S", 0},
        };
        for (const auto &entry : triggers) {
            const QByteArray ical =
                "BEGIN:VEVENT\r\nUID:alarm-test\r\n"
                "DTSTART:20260819T091500Z\r\nDTEND:20260819T093000Z\r\n"
                "SUMMARY:Standup\r\nBEGIN:VALARM\r\nACTION:DISPLAY\r\n"
                "DESCRIPTION:Standup\r\nTRIGGER:" + entry.first
                + "\r\nEND:VALARM\r\nEND:VEVENT\r\n";
            ICalComponent *component = i_cal_component_new_from_string(ical.constData());
            QVERIFY2(component, entry.first.constData());
            const QVariantMap parsed = CalendarStore::eventFromComponent(component);
            g_object_unref(component);
            QCOMPARE(parsed.value(QStringLiteral("alarms")).toList(),
                     QVariantList({entry.second}));
        }
    }

    void recurrenceRuleRoundTrips() {
        QVariantMap event;
        event.insert(QStringLiteral("summary"), QStringLiteral("Standup"));
        event.insert(QStringLiteral("allDay"), false);
        const QDateTime start(QDate(2026, 8, 19), QTime(9, 15));
        event.insert(QStringLiteral("startMs"), double(start.toMSecsSinceEpoch()));
        event.insert(QStringLiteral("endMs"),
                     double(start.addSecs(900).toMSecsSinceEpoch()));
        event.insert(QStringLiteral("rrule"),
                     QStringLiteral("FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"));

        ICalComponent *component = CalendarStore::componentFromEvent(event);
        QVariantMap parsed = CalendarStore::eventFromComponent(component);
        QVERIFY(parsed.value(QStringLiteral("rrule")).toString()
                    .contains(QStringLiteral("FREQ=WEEKLY")));
        QVERIFY(parsed.value(QStringLiteral("recurring")).toBool());
        // The series master's first occurrence is the series start.
        QVERIFY(parsed.value(QStringLiteral("isFirstOccurrence")).toBool());

        // Clearing the rule drops the RRULE and the recurring flag.
        event.insert(QStringLiteral("rrule"), QString());
        CalendarStore::applyEventToComponent(component, event);
        parsed = CalendarStore::eventFromComponent(component);
        QCOMPARE(parsed.value(QStringLiteral("rrule")).toString(), QString());
        QVERIFY(!parsed.value(QStringLiteral("recurring")).toBool());
        QCOMPARE(i_cal_component_count_properties(component, I_CAL_RRULE_PROPERTY), 0);
        g_object_unref(component);
    }

    void occurrenceKeepsSeriesRule() {
        // An event map without an "rrule" key must never touch an existing
        // rule — that is how per-occurrence edits stay non-destructive.
        QVariantMap event;
        event.insert(QStringLiteral("summary"), QStringLiteral("Standup"));
        event.insert(QStringLiteral("allDay"), false);
        event.insert(QStringLiteral("startMs"), double(0));
        event.insert(QStringLiteral("endMs"), double(900000));
        event.insert(QStringLiteral("rrule"), QStringLiteral("FREQ=DAILY"));
        ICalComponent *component = CalendarStore::componentFromEvent(event);

        QVariantMap edit = event;
        edit.remove(QStringLiteral("rrule"));
        edit.insert(QStringLiteral("summary"), QStringLiteral("Renamed"));
        CalendarStore::applyEventToComponent(component, edit);

        const QVariantMap parsed = CalendarStore::eventFromComponent(component);
        QCOMPARE(parsed.value(QStringLiteral("summary")).toString(),
                 QStringLiteral("Renamed"));
        QVERIFY(parsed.value(QStringLiteral("rrule")).toString()
                    .contains(QStringLiteral("FREQ=DAILY")));
        g_object_unref(component);
    }

    void clearedFieldsLeaveNoBrokenProperty() {
        // libical writes an empty value as a property with no value, then
        // refuses to parse that back and leaves an X-LIC-ERROR in its place,
        // which every other client shows as junk.
        QVariantMap event;
        event.insert(QStringLiteral("summary"), QStringLiteral("Standup"));
        event.insert(QStringLiteral("location"), QStringLiteral("Room 2"));
        event.insert(QStringLiteral("description"), QStringLiteral("notes"));
        event.insert(QStringLiteral("allDay"), false);
        event.insert(QStringLiteral("startMs"), double(0));
        event.insert(QStringLiteral("endMs"), double(3600000));
        ICalComponent *component = CalendarStore::componentFromEvent(event);

        event.insert(QStringLiteral("location"), QString());
        event.insert(QStringLiteral("description"), QString());
        CalendarStore::applyEventToComponent(component, event);

        gchar *text = i_cal_component_as_ical_string(component);
        ICalComponent *reparsed = i_cal_component_new_from_string(text);
        g_free(text);
        QVERIFY(reparsed);
        QCOMPARE(i_cal_component_count_properties(reparsed, I_CAL_XLICERROR_PROPERTY), 0);
        QCOMPARE(i_cal_component_count_properties(reparsed, I_CAL_LOCATION_PROPERTY), 0);
        QCOMPARE(i_cal_component_count_properties(reparsed, I_CAL_DESCRIPTION_PROPERTY), 0);
        QCOMPARE(CalendarStore::eventFromComponent(reparsed)
                     .value(QStringLiteral("summary")).toString(),
                 QStringLiteral("Standup"));
        g_object_unref(reparsed);
        g_object_unref(component);
    }

    void detachedOccurrenceDropsTheSeriesRule() {
        // An occurrence edited on its own is stored as a second component
        // carrying a RECURRENCE-ID. Keeping the master's RRULE on it would
        // make that single exception a series of its own.
        QVariantMap event;
        event.insert(QStringLiteral("summary"), QStringLiteral("Standup"));
        event.insert(QStringLiteral("allDay"), false);
        const QDateTime start(QDate(2026, 8, 17), QTime(9, 0));
        event.insert(QStringLiteral("startMs"), double(start.toMSecsSinceEpoch()));
        event.insert(QStringLiteral("endMs"),
                     double(start.addSecs(1800).toMSecsSinceEpoch()));
        event.insert(QStringLiteral("rrule"), QStringLiteral("FREQ=WEEKLY;BYDAY=MO"));
        ICalComponent *master = CalendarStore::componentFromEvent(event);

        // The second occurrence, a week on: construct_instance() only
        // answers for a RECURRENCE-ID the series actually lands on.
        ICalTime *rid = i_cal_component_get_dtstart(master);
        i_cal_time_adjust(rid, 7, 0, 0, 0);
        ICalComponent *instance = e_cal_util_construct_instance(master, rid);
        g_object_unref(rid);
        QVERIFY(instance);
        // The clone arrives with the series rule still on it.
        QCOMPARE(i_cal_component_count_properties(instance, I_CAL_RRULE_PROPERTY), 1);

        CalendarStore::stripSeriesRules(instance);
        QCOMPARE(i_cal_component_count_properties(instance, I_CAL_RRULE_PROPERTY), 0);
        QCOMPARE(i_cal_component_count_properties(instance, I_CAL_RDATE_PROPERTY), 0);
        QCOMPARE(i_cal_component_count_properties(instance, I_CAL_EXDATE_PROPERTY), 0);
        // The master keeps its own, and the exception stays an exception.
        QCOMPARE(i_cal_component_count_properties(master, I_CAL_RRULE_PROPERTY), 1);
        QCOMPARE(i_cal_component_count_properties(instance, I_CAL_RECURRENCEID_PROPERTY), 1);

        g_object_unref(instance);
        g_object_unref(master);
    }

    void freshComponentsGetUniqueUids() {
        QVariantMap event;
        event.insert(QStringLiteral("allDay"), false);
        event.insert(QStringLiteral("startMs"), double(0));
        event.insert(QStringLiteral("endMs"), double(3600000));

        ICalComponent *first = CalendarStore::componentFromEvent(event);
        ICalComponent *second = CalendarStore::componentFromEvent(event);
        const QString firstUid = QString::fromUtf8(i_cal_component_get_uid(first));
        const QString secondUid = QString::fromUtf8(i_cal_component_get_uid(second));
        g_object_unref(first);
        g_object_unref(second);

        QVERIFY(!firstUid.isEmpty());
        QVERIFY(firstUid != secondUid);
    }

private:
    QTemporaryDir m_settingsDirectory;
};

QTEST_GUILESS_MAIN(OmacalTest)
#include "tst_omacal.moc"
