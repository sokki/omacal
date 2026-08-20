// EDS headers must come before any Qt header: GIO's introspection structs use
// "signals" as a field name, which Qt's signal macro would otherwise mangle.
#include <libecal/libecal.h>

#include "calendarstore.h"

#include <QCoreApplication>
#include <QDebug>
#include <QElapsedTimer>
#include <QMetaObject>
#include <QPointer>

#include <algorithm>
#include <utility>

namespace {

// User data for GLib async callbacks. The QPointer keeps a store that was
// torn down mid-flight from being touched; each callback deletes its ref.
struct StoreRef {
    QPointer<CalendarStore> store;
    QString id;
    QVariantMap event;
    ICalComponent *component = nullptr;
    QString context = {}; // error-report prefix for the shared write helpers

    ~StoreRef() {
        if (component)
            g_object_unref(component);
    }
};

// Accumulator for e_cal_client_generate_instances(), which invokes its
// callbacks from a worker thread; only plain data is touched there and the
// result is marshalled back to the store's thread on completion.
struct InstanceCollect {
    QPointer<CalendarStore> store;
    QString id;
    QVariantList instances;
    QString needle;     // search runs only: case-insensitive match text
    int generation = 0; // search runs only: stale-reply guard
};

QString errorText(const GError *error) {
    return error && error->message ? QString::fromUtf8(error->message)
                                   : QStringLiteral("unknown error");
}

bool wasCancelled(const GError *error) {
    return error && g_error_matches(error, G_IO_ERROR, G_IO_ERROR_CANCELLED);
}

// The backend's mod type for a scope string; anything unrecognised falls to
// "this", matching the QML default.
ECalObjModType modTypeForScope(const QString &scope) {
    if (scope == QStringLiteral("all"))
        return E_CAL_OBJ_MOD_ALL;
    return scope == QStringLiteral("future") ? E_CAL_OBJ_MOD_THIS_AND_FUTURE
                                             : E_CAL_OBJ_MOD_THIS;
}

qint64 timeToMs(ICalTime *time) {
    if (i_cal_time_is_date(time)) {
        // Date-only values have no timezone; anchor them to local midnight so
        // an all-day event stays on its calendar day wherever it is shown.
        const QDate date(i_cal_time_get_year(time), i_cal_time_get_month(time),
                         i_cal_time_get_day(time));
        return date.startOfDay().toMSecsSinceEpoch();
    }
    ICalTimezone *zone = i_cal_time_get_timezone(time);
    return static_cast<qint64>(i_cal_time_as_timet_with_zone(time, zone)) * 1000;
}

// A DTSTART/DTEND value for the given epoch milliseconds. Timed values are
// written in UTC, which every client renders back in its own local time.
ICalTime *timeFromMs(qint64 ms, bool allDay) {
    if (allDay) {
        const QDate date = QDateTime::fromMSecsSinceEpoch(ms).date();
        ICalTime *time = i_cal_time_new_null_time();
        i_cal_time_set_date(time, date.year(), date.month(), date.day());
        i_cal_time_set_is_date(time, TRUE);
        return time;
    }
    return i_cal_time_new_from_timet_with_zone(static_cast<time_t>(ms / 1000), FALSE,
                                               i_cal_timezone_get_utc_timezone());
}

// A duration in seconds, summed from its own fields: libical-glib's
// i_cal_duration_as_seconds() answers 0 for day- and week-based durations,
// so an externally written "-P1D" alarm would read as "at time of event".
qint64 durationSeconds(ICalDuration *duration) {
    const qint64 seconds =
        qint64(i_cal_duration_get_weeks(duration)) * 604800
        + qint64(i_cal_duration_get_days(duration)) * 86400
        + qint64(i_cal_duration_get_hours(duration)) * 3600
        + qint64(i_cal_duration_get_minutes(duration)) * 60
        + qint64(i_cal_duration_get_seconds(duration));
    return i_cal_duration_is_neg(duration) ? -seconds : seconds;
}

// The event's alerts as minutes before the start (negative = after), in
// component order. Only relative triggers are read; absolute-time alarms are
// neither shown nor misread (and get dropped on save, like every
// rewrite-based editor does).
QVariantList alarmsFromComponent(ICalComponent *component) {
    QVariantList alarms;
    for (ICalComponent *alarm = i_cal_component_get_first_component(
             component, I_CAL_VALARM_COMPONENT);
         alarm;
         alarm = i_cal_component_get_next_component(component, I_CAL_VALARM_COMPONENT)) {
        ICalProperty *triggerProperty =
            i_cal_component_get_first_property(alarm, I_CAL_TRIGGER_PROPERTY);
        if (!triggerProperty) {
            g_object_unref(alarm);
            continue;
        }

        ICalTrigger *trigger = i_cal_property_get_trigger(triggerProperty);
        ICalDuration *duration = trigger ? i_cal_trigger_get_duration(trigger) : nullptr;
        ICalTime *triggerTime = trigger ? i_cal_trigger_get_time(trigger) : nullptr;
        bool relative = false;
        int minutes = 0;
        if (duration && !i_cal_duration_is_null_duration(duration)) {
            relative = true;
            minutes = int(-durationSeconds(duration) / 60);
        } else if (duration && (!triggerTime || i_cal_time_is_null_time(triggerTime))) {
            relative = true; // A zero offset parses as the null duration.
        }

        if (triggerTime)
            g_object_unref(triggerTime);
        if (duration)
            g_object_unref(duration);
        if (trigger)
            g_object_unref(trigger);
        g_object_unref(triggerProperty);
        g_object_unref(alarm);
        if (relative && !alarms.contains(minutes))
            alarms.append(minutes);
    }
    return alarms;
}

void setAlarmsOnComponent(ICalComponent *component, const QVariantList &alarms,
                          const QString &summary) {
    // The alert list is authoritative: rewrite whatever is there.
    QList<ICalComponent *> stale;
    for (ICalComponent *alarm = i_cal_component_get_first_component(
             component, I_CAL_VALARM_COMPONENT);
         alarm;
         alarm = i_cal_component_get_next_component(component, I_CAL_VALARM_COMPONENT))
        stale.append(alarm);
    for (ICalComponent *alarm : stale) {
        i_cal_component_remove_component(component, alarm);
        g_object_unref(alarm);
    }

    QList<int> written;
    for (const QVariant &value : alarms) {
        const int minutes = value.toInt();
        if (written.contains(minutes))
            continue;
        written.append(minutes);

        ICalComponent *alarm = i_cal_component_new_valarm();
        i_cal_component_take_property(alarm,
                                      i_cal_property_new_action(I_CAL_ACTION_DISPLAY));
        i_cal_component_take_property(alarm, i_cal_property_new_description(
            summary.isEmpty() ? "Reminder" : summary.toUtf8().constData()));

        // Positive minutes are before the start, negative after.
        const QString triggerText = minutes == 0
            ? QStringLiteral("PT0S")
            : minutes > 0 ? QStringLiteral("-PT%1M").arg(minutes)
                          : QStringLiteral("PT%1M").arg(-minutes);
        ICalTrigger *trigger =
            i_cal_trigger_new_from_string(triggerText.toUtf8().constData());
        i_cal_component_take_property(alarm, i_cal_property_new_trigger(trigger));
        g_object_unref(trigger);

        i_cal_component_take_component(component, alarm);
    }
}

// libical serialises an empty string as a property with no value at all,
// which it then refuses to parse back: the component returns from the
// backend carrying an X-LIC-ERROR in its place, and every other client shows
// that junk. Clearing a field has to remove the property instead.
void setTextProperty(ICalComponent *component, ICalPropertyKind kind,
                     const QString &value,
                     void (*setter)(ICalComponent *, const gchar *)) {
    if (value.isEmpty())
        i_cal_component_remove_property_by_kind(component, kind);
    else
        setter(component, value.toUtf8().constData());
}

QString componentIcal(ICalComponent *component) {
    gchar *text = i_cal_component_as_ical_string(component);
    const QString result = QString::fromUtf8(text);
    g_free(text);
    return result;
}

QString instanceRecurrenceId(ICalComponent *component, ICalTime *instanceStart) {
    // A detached instance carries its own RECURRENCE-ID, which can differ
    // from the occurrence start when the instance was moved.
    ICalProperty *ridProperty =
        i_cal_component_get_first_property(component, I_CAL_RECURRENCEID_PROPERTY);
    ICalTime *rid = ridProperty ? i_cal_property_get_recurrenceid(ridProperty)
                                : nullptr;
    gchar *text = i_cal_time_as_ical_string(rid ? rid : instanceStart);
    const QString result = QString::fromUtf8(text);
    g_free(text);
    if (rid)
        g_object_unref(rid);
    if (ridProperty)
        g_object_unref(ridProperty);
    return result;
}

QVariantMap instanceToMap(const QString &calendarId, ICalComponent *component,
                          ICalTime *instanceStart, ICalTime *instanceEnd) {
    QVariantMap map;
    map.insert(QStringLiteral("calendarId"), calendarId);
    map.insert(QStringLiteral("uid"), QString::fromUtf8(i_cal_component_get_uid(component)));

    const auto text = [](const gchar *value) {
        return value ? QString::fromUtf8(value) : QString();
    };
    map.insert(QStringLiteral("summary"), text(i_cal_component_get_summary(component)));
    map.insert(QStringLiteral("location"), text(i_cal_component_get_location(component)));
    map.insert(QStringLiteral("description"), text(i_cal_component_get_description(component)));

    map.insert(QStringLiteral("allDay"), i_cal_time_is_date(instanceStart) == TRUE);
    map.insert(QStringLiteral("startMs"), double(timeToMs(instanceStart)));
    map.insert(QStringLiteral("endMs"), double(timeToMs(instanceEnd)));
    map.insert(QStringLiteral("alarms"), alarmsFromComponent(component));

    ICalProperty *ridProperty =
        i_cal_component_get_first_property(component, I_CAL_RECURRENCEID_PROPERTY);
    const bool recurring = e_cal_util_component_has_recurrences(component) == TRUE
        || ridProperty != nullptr;
    map.insert(QStringLiteral("recurring"), recurring);
    map.insert(QStringLiteral("recurrenceId"),
               recurring ? instanceRecurrenceId(component, instanceStart) : QString());

    // The recurrence rule (editable on the series) and whether this
    // occurrence is the series' first — the "all future" scope makes no
    // sense on the first occurrence.
    QString rrule;
    ICalProperty *rruleProperty =
        i_cal_component_get_first_property(component, I_CAL_RRULE_PROPERTY);
    if (rruleProperty) {
        ICalRecurrence *recurrence = i_cal_property_get_rrule(rruleProperty);
        if (recurrence) {
            gchar *text = i_cal_recurrence_to_string(recurrence);
            rrule = QString::fromUtf8(text);
            g_free(text);
            g_object_unref(recurrence);
        }
        g_object_unref(rruleProperty);
    }
    map.insert(QStringLiteral("rrule"), rrule);

    bool firstOccurrence = !recurring;
    if (recurring && !ridProperty) {
        ICalTime *seriesStart = i_cal_component_get_dtstart(component);
        firstOccurrence = seriesStart
            && i_cal_time_compare(seriesStart, instanceStart) == 0;
        if (seriesStart)
            g_object_unref(seriesStart);
    }
    map.insert(QStringLiteral("isFirstOccurrence"), firstOccurrence);
    if (ridProperty)
        g_object_unref(ridProperty);
    return map;
}

}

void CalendarStore::stripSeriesRules(ICalComponent *component) {
    // e_cal_util_construct_instance() clones the master whole, rules
    // included, so an occurrence detached from it would otherwise repeat on
    // its own — invalid alongside a RECURRENCE-ID, and enough to confuse the
    // clients that go on to read it.
    for (ICalPropertyKind kind : {I_CAL_RRULE_PROPERTY, I_CAL_RDATE_PROPERTY,
                                  I_CAL_EXRULE_PROPERTY, I_CAL_EXDATE_PROPERTY})
        i_cal_component_remove_property_by_kind(component, kind);
}

void CalendarStore::applyEventToComponent(ICalComponent *component, const QVariantMap &event) {
    // Anything an earlier save left unparseable goes now, so a component
    // stops carrying the mistake once it is edited again.
    i_cal_component_strip_errors(component);

    setTextProperty(component, I_CAL_SUMMARY_PROPERTY,
                    event.value(QStringLiteral("summary")).toString(),
                    i_cal_component_set_summary);
    setTextProperty(component, I_CAL_LOCATION_PROPERTY,
                    event.value(QStringLiteral("location")).toString(),
                    i_cal_component_set_location);
    setTextProperty(component, I_CAL_DESCRIPTION_PROPERTY,
                    event.value(QStringLiteral("description")).toString(),
                    i_cal_component_set_description);

    const bool allDay = event.value(QStringLiteral("allDay")).toBool();
    ICalTime *start = timeFromMs(qint64(event.value(QStringLiteral("startMs")).toDouble()), allDay);
    ICalTime *end = timeFromMs(qint64(event.value(QStringLiteral("endMs")).toDouble()), allDay);
    i_cal_component_set_dtstart(component, start);
    i_cal_component_set_dtend(component, end);
    g_object_unref(start);
    g_object_unref(end);

    setAlarmsOnComponent(component,
                         event.value(QStringLiteral("alarms")).toList(),
                         event.value(QStringLiteral("summary")).toString());

    // The recurrence rule lives on the series master only; an occurrence
    // (RECURRENCE-ID set) never carries one.
    if (event.contains(QStringLiteral("rrule"))) {
        ICalProperty *ridProperty = i_cal_component_get_first_property(
            component, I_CAL_RECURRENCEID_PROPERTY);
        if (!ridProperty) {
            i_cal_component_remove_property_by_kind(component, I_CAL_RRULE_PROPERTY);
            const QString rule = event.value(QStringLiteral("rrule")).toString();
            if (!rule.isEmpty()) {
                ICalRecurrence *recurrence =
                    i_cal_recurrence_new_from_string(rule.toUtf8().constData());
                if (recurrence) {
                    i_cal_component_take_property(component,
                                                  i_cal_property_new_rrule(recurrence));
                    g_object_unref(recurrence);
                }
            }
        } else {
            g_object_unref(ridProperty);
        }
    }
}

// Pipeline timing, printed only with OMACAL_PERF=1 in the environment (pair
// with QT_FORCE_STDERR_LOGGING=1 to see it on a terminal).
namespace {
QElapsedTimer perfTimer;
bool perfEnabled() {
    static const bool enabled = qEnvironmentVariableIsSet("OMACAL_PERF");
    return enabled;
}
}
#define PERF(msg) \
    do { \
        if (perfEnabled()) \
            qWarning().noquote() << "[perf" << perfTimer.elapsed() << "ms]" << (msg); \
    } while (false)

CalendarStore::CalendarStore(QObject *parent) : QObject(parent) {
    perfTimer.start();
    PERF("store created");
    m_cancellable = g_cancellable_new();

    m_reloadTimer.setSingleShot(true);
    m_reloadTimer.setInterval(150);
    connect(&m_reloadTimer, &QTimer::timeout, this, [this]() {
        const QSet<QString> pending = m_pendingReloads;
        m_pendingReloads.clear();
        for (const QString &id : pending)
            reloadCalendar(id);
    });

    m_rebuildTimer.setSingleShot(true);
    m_rebuildTimer.setInterval(0);
    connect(&m_rebuildTimer, &QTimer::timeout, this, &CalendarStore::rebuildEventList);

    auto *ref = new StoreRef{this, {}, {}, nullptr};
    e_source_registry_new(
        m_cancellable,
        [](GObject *, GAsyncResult *result, gpointer userData) {
            auto *ref = static_cast<StoreRef *>(userData);
            GError *error = nullptr;
            ESourceRegistry *registry = e_source_registry_new_finish(result, &error);
            if (registry && ref->store)
                ref->store->registryReady(registry);
            else if (registry)
                g_object_unref(registry);
            else if (ref->store && !wasCancelled(error))
                ref->store->reportError(QStringLiteral("Calendar service"), errorText(error));
            g_clear_error(&error);
            delete ref;
        },
        ref);
}

CalendarStore::~CalendarStore() {
    g_cancellable_cancel(m_cancellable);

    for (Calendar &calendar : m_calendars) {
        if (calendar.view) {
            g_signal_handlers_disconnect_by_data(calendar.view, this);
            g_object_unref(calendar.view);
        }
        if (calendar.client)
            g_object_unref(calendar.client);
        if (calendar.source)
            g_object_unref(calendar.source);
    }
    if (m_registry) {
        for (ulong handler : m_registryHandlers)
            if (handler)
                g_signal_handler_disconnect(m_registry, handler);
        g_object_unref(m_registry);
    }
    g_object_unref(m_cancellable);
}

void CalendarStore::registryReady(ESourceRegistry *registry) {
    PERF("registry ready");
    m_registry = registry;

    const auto onSourceAdded = [](ESourceRegistry *, ESource *source, gpointer userData) {
        static_cast<CalendarStore *>(userData)->addSource(source);
    };
    const auto onSourceRemoved = [](ESourceRegistry *, ESource *source, gpointer userData) {
        static_cast<CalendarStore *>(userData)
            ->removeSource(QString::fromUtf8(e_source_get_uid(source)));
    };
    const auto onSourceChanged = [](ESourceRegistry *, ESource *source, gpointer userData) {
        static_cast<CalendarStore *>(userData)->refreshSourceEntry(source);
    };
    m_registryHandlers[0] = g_signal_connect(
        m_registry, "source-added", G_CALLBACK(+onSourceAdded), this);
    m_registryHandlers[1] = g_signal_connect(
        m_registry, "source-removed", G_CALLBACK(+onSourceRemoved), this);
    m_registryHandlers[2] = g_signal_connect(
        m_registry, "source-changed", G_CALLBACK(+onSourceChanged), this);

    GList *sources = e_source_registry_list_enabled(m_registry, E_SOURCE_EXTENSION_CALENDAR);
    for (GList *link = sources; link; link = link->next)
        addSource(E_SOURCE(link->data));
    g_list_free_full(sources, g_object_unref);

    m_ready = true;
    emit readyChanged();
}

void CalendarStore::addSource(ESource *source) {
    if (!e_source_has_extension(source, E_SOURCE_EXTENSION_CALENDAR)
            || !e_source_get_enabled(source))
        return;

    const QString id = QString::fromUtf8(e_source_get_uid(source));
    if (m_calendars.contains(id))
        return;

    Calendar calendar;
    calendar.id = id;
    calendar.source = E_SOURCE(g_object_ref(source));
    m_calendars.insert(id, calendar);
    rebuildCalendarList();

    connectClient(m_calendars[id]);
}

void CalendarStore::connectClient(Calendar &calendar) {
    auto *ref = new StoreRef{this, calendar.id, {}, nullptr};
    // Cap the "connected" handshake at one second: operations queue until
    // the backend is ready anyway, and sources whose backend never reports
    // connected (e.g. children of plain grouping sources) otherwise stall
    // the full wait before showing anything. Zero is no good either — it
    // skips the rendezvous that nudges such backends open at all.
    e_cal_client_connect(
        calendar.source, E_CAL_CLIENT_SOURCE_TYPE_EVENTS, 1, m_cancellable,
        [](GObject *, GAsyncResult *result, gpointer userData) {
            auto *ref = static_cast<StoreRef *>(userData);
            GError *error = nullptr;
            EClient *client = e_cal_client_connect_finish(result, &error);
            if (client && ref->store)
                ref->store->clientConnected(ref->id, E_CAL_CLIENT(client));
            else if (client)
                g_object_unref(client);
            else if (ref->store && !wasCancelled(error))
                ref->store->reportError(QStringLiteral("Opening calendar"), errorText(error));
            g_clear_error(&error);
            delete ref;
        },
        ref);
}

void CalendarStore::clientConnected(const QString &id, ECalClient *client) {
    PERF("client connected " + id);
    Calendar *calendar = calendarFor(id);
    if (!calendar) {
        g_object_unref(client);
        return;
    }

    calendar->client = client;
    // Floating and DATE values resolve against this; the client would
    // otherwise assume UTC and shift them.
    if (ICalTimezone *zone = e_cal_util_get_system_timezone())
        e_cal_client_set_default_timezone(client, zone);
    rebuildCalendarList();
    reloadCalendar(id);
    // Pick up a name or colour changed on the server since last time.
    fetchWebdavProperties(calendar->source);

    auto *ref = new StoreRef{this, id, {}, nullptr};
    e_cal_client_get_view(
        client, "#t", m_cancellable,
        [](GObject *sourceObject, GAsyncResult *result, gpointer userData) {
            auto *ref = static_cast<StoreRef *>(userData);
            GError *error = nullptr;
            ECalClientView *view = nullptr;
            if (e_cal_client_get_view_finish(E_CAL_CLIENT(sourceObject), result, &view, &error)
                    && ref->store) {
                ref->store->viewReady(ref->id, view);
            } else if (view) {
                g_object_unref(view);
            } else if (ref->store && !wasCancelled(error)) {
                ref->store->reportError(QStringLiteral("Watching calendar"), errorText(error));
            }
            g_clear_error(&error);
            delete ref;
        },
        ref);
}

void CalendarStore::viewReady(const QString &id, ECalClientView *view) {
    Calendar *calendar = calendarFor(id);
    if (!calendar) {
        g_object_unref(view);
        return;
    }

    calendar->view = view;

    // Any change in the backing calendar reloads its occurrences; the actual
    // payloads are ignored because recurrence expansion has to rerun anyway.
    const auto onChanged = [](ECalClientView *view, gpointer, gpointer userData) {
        static_cast<CalendarStore *>(userData)->viewChanged(view);
    };
    g_signal_connect(view, "objects-added", G_CALLBACK(+onChanged), this);
    g_signal_connect(view, "objects-modified", G_CALLBACK(+onChanged), this);
    g_signal_connect(view, "objects-removed", G_CALLBACK(+onChanged), this);

    GError *error = nullptr;
    e_cal_client_view_start(view, &error);
    if (error) {
        reportError(QStringLiteral("Watching calendar"), errorText(error));
        g_clear_error(&error);
    }
}

void CalendarStore::viewChanged(ECalClientView *view) {
    for (const Calendar &calendar : std::as_const(m_calendars)) {
        if (calendar.view == view) {
            scheduleReload(calendar.id);
            return;
        }
    }
}

void CalendarStore::removeSource(const QString &id) {
    const auto it = m_calendars.constFind(id);
    if (it == m_calendars.constEnd())
        return;

    Calendar calendar = *it;
    m_calendars.erase(it);

    if (calendar.view) {
        g_signal_handlers_disconnect_by_data(calendar.view, this);
        g_object_unref(calendar.view);
    }
    if (calendar.client)
        g_object_unref(calendar.client);
    if (calendar.source)
        g_object_unref(calendar.source);

    rebuildCalendarList();
    rebuildEventList();
}

void CalendarStore::refreshSourceEntry(ESource *source) {
    const QString id = QString::fromUtf8(e_source_get_uid(source));
    Calendar *calendar = calendarFor(id);
    if (!calendar) {
        addSource(source);
        return;
    }
    if (!e_source_get_enabled(source)) {
        removeSource(id);
        return;
    }

    rebuildCalendarList();

    // Metadata edits (name, colour) never touch the event list; only the
    // selected flag does — and our own writes already rebuilt for it, so
    // this catches flips arriving from other clients.
    ESourceSelectable *selectable = E_SOURCE_SELECTABLE(
        e_source_get_extension(source, E_SOURCE_EXTENSION_CALENDAR));
    if ((e_source_selectable_get_selected(selectable) == TRUE)
            != calendar->selectedInEventList)
        rebuildEventList();
}

void CalendarStore::setVisibleRange(double startMs, double endMs) {
    // A day of slack on both sides keeps events that cross midnight in a
    // different timezone from vanishing at the edges of the view.
    const QDateTime start =
        QDateTime::fromMSecsSinceEpoch(qint64(startMs)).addDays(-1);
    const QDateTime end = QDateTime::fromMSecsSinceEpoch(qint64(endMs)).addDays(1);

    // Regenerating every calendar's occurrences is the expensive step, so
    // the loaded window is padded by three months on both sides and month
    // navigation inside it is served entirely from the cache; only crossing
    // the window's edge reloads (and re-pads around the new position).
    if (m_rangeStart.isValid() && start >= m_rangeStart && end <= m_rangeEnd)
        return;

    m_rangeStart = start.addMonths(-3);
    m_rangeEnd = end.addMonths(3);
    for (const QString &id : std::as_const(m_calendarOrder))
        scheduleReload(id);
}

void CalendarStore::scheduleReload(const QString &id) {
    m_pendingReloads.insert(id);
    m_reloadTimer.start();
}

namespace {

struct InstanceRun {
    ECalClient *client = nullptr;
    time_t from = 0;
    time_t to = 0;
    ECalRecurInstanceCb callback = nullptr;
    gpointer userData = nullptr;
    GDestroyNotify done = nullptr;
};

// Expanding a range, the way gnome-calendar does it.
//
// e_cal_client_generate_instances() would be the one-liner, but it expands
// exactly what the backend's range query returns — and the local file
// backend answers such a query with the series master alone, never its
// detached instances. Every "only this" edit then stays invisible, while the
// same edit shows up fine on CalDAV, whose cache does return the overrides.
// Asking libecal per object instead makes it look the overrides up by UID
// itself, so both kinds of backend come out the same.
void expandRangeThread(GTask *task, gpointer, gpointer taskData,
                       GCancellable *cancellable) {
    auto *run = static_cast<InstanceRun *>(taskData);
    ICalTimezone *utc = i_cal_timezone_get_utc_timezone();
    ICalTime *from = i_cal_time_new_from_timet_with_zone(run->from, FALSE, utc);
    ICalTime *to = i_cal_time_new_from_timet_with_zone(run->to, FALSE, utc);
    gchar *fromText = i_cal_time_as_ical_string(from);
    gchar *toText = i_cal_time_as_ical_string(to);
    gchar *sexp = g_strdup_printf(
        "(occur-in-time-range? (make-time \"%s\") (make-time \"%s\"))", fromText, toText);

    GSList *objects = nullptr;
    GError *error = nullptr;
    if (e_cal_client_get_object_list_sync(run->client, sexp, &objects, cancellable, &error)) {
        // Which series have their master in this window: an override belonging
        // to one is emitted by that master's expansion, and reporting it again
        // here would double it on the backends that do return overrides.
        GHashTable *masters = g_hash_table_new(g_str_hash, g_str_equal);
        for (GSList *l = objects; l; l = l->next) {
            auto *component = static_cast<ICalComponent *>(l->data);
            if (e_cal_util_component_has_recurrences(component)
                    && !e_cal_util_component_is_instance(component))
                g_hash_table_add(masters,
                                 const_cast<gchar *>(i_cal_component_get_uid(component)));
        }

        for (GSList *l = objects; l && !g_cancellable_is_cancelled(cancellable);
                l = l->next) {
            auto *component = static_cast<ICalComponent *>(l->data);
            if (e_cal_util_component_is_instance(component)
                    && g_hash_table_contains(masters, i_cal_component_get_uid(component)))
                continue;
            // Non-recurring components come straight back out of this, so it
            // costs no more than expanding them here would.
            e_cal_client_generate_instances_for_object_sync(
                run->client, component, run->from, run->to, cancellable,
                run->callback, run->userData);
        }
        g_hash_table_destroy(masters);
        g_slist_free_full(objects, g_object_unref);
    }

    g_clear_error(&error);
    g_free(sexp);
    g_free(fromText);
    g_free(toText);
    g_object_unref(from);
    g_object_unref(to);
    g_task_return_boolean(task, TRUE);
}

// Same shape as e_cal_client_generate_instances(): the callback runs on a
// worker thread for every occurrence, and done() is handed the user data
// once, after the last one.
void generateInstances(ECalClient *client, time_t from, time_t to,
                       GCancellable *cancellable, ECalRecurInstanceCb callback,
                       gpointer userData, GDestroyNotify done) {
    auto *run = new InstanceRun{E_CAL_CLIENT(g_object_ref(client)), from, to,
                                callback, userData, done};
    GTask *task = g_task_new(nullptr, cancellable, nullptr, nullptr);
    g_task_set_task_data(task, run, [](gpointer data) {
        auto *run = static_cast<InstanceRun *>(data);
        if (run->done)
            run->done(run->userData);
        g_object_unref(run->client);
        delete run;
    });
    g_task_run_in_thread(task, expandRangeThread);
    g_object_unref(task);
}

}

void CalendarStore::reloadCalendar(const QString &id) {
    Calendar *calendar = calendarFor(id);
    if (!calendar || !calendar->client || !m_rangeStart.isValid())
        return;
    if (calendar->loading) {
        calendar->reloadQueued = true;
        return;
    }
    calendar->loading = true;
    PERF("generate_instances start " + id);
    updateSyncing();

    // The instance callbacks run on a worker thread, so they only fill the
    // collector; the result hops back to this thread when done.
    auto *collect = new InstanceCollect{this, id, {}};
    generateInstances(
        calendar->client, m_rangeStart.toSecsSinceEpoch(), m_rangeEnd.toSecsSinceEpoch(),
        m_cancellable,
        [](ICalComponent *component, ICalTime *instanceStart, ICalTime *instanceEnd,
           gpointer userData, GCancellable *, GError **) -> gboolean {
            auto *collect = static_cast<InstanceCollect *>(userData);
            collect->instances.append(
                instanceToMap(collect->id, component, instanceStart, instanceEnd));
            return TRUE;
        },
        collect, instanceRunDone);
}

// GDestroyNotify of both instance runs. The collector was filled on EDS's
// worker thread; everything else happens back on the store's thread. A
// non-empty needle marks a search run.
void CalendarStore::instanceRunDone(void *data) {
    auto *collect = static_cast<InstanceCollect *>(data);
    QMetaObject::invokeMethod(
        QCoreApplication::instance(),
        [collect]() {
            if (collect->store) {
                if (collect->needle.isEmpty())
                    collect->store->instancesLoaded(collect->id, collect->instances);
                else
                    collect->store->searchResultsArrived(collect->generation,
                                                         collect->instances);
            }
            delete collect;
        },
        Qt::QueuedConnection);
}

void CalendarStore::instancesLoaded(const QString &id, const QVariantList &instances) {
    PERF("instances loaded " + id + " count " + QString::number(instances.size()));
    Calendar *calendar = calendarFor(id);
    if (!calendar)
        return;

    calendar->loading = false;
    calendar->events = instances;
    if (calendar->reloadQueued) {
        calendar->reloadQueued = false;
        scheduleReload(id);
    }
    // Coalesced: with several calendars loading, each arrival would
    // otherwise concat and re-sort the full list again.
    m_rebuildTimer.start();
    updateSyncing();
}

void CalendarStore::refreshAll() {
    for (const QString &id : std::as_const(m_calendarOrder)) {
        Calendar *calendar = calendarFor(id);
        if (!calendar || !calendar->client)
            continue;

        // A sync also re-reads the calendar's own name and colour, which EDS
        // itself only revisits when it re-discovers a whole account.
        fetchWebdavProperties(calendar->source);

        // Local calendars have nothing to fetch; a reload is their refresh.
        if (!e_client_check_refresh_supported(E_CLIENT(calendar->client))) {
            scheduleReload(id);
            continue;
        }

        ++m_refreshPending;
        auto *ref = new StoreRef{this, id, {}, nullptr};
        e_client_refresh(
            E_CLIENT(calendar->client), m_cancellable,
            [](GObject *sourceObject, GAsyncResult *result, gpointer userData) {
                auto *ref = static_cast<StoreRef *>(userData);
                GError *error = nullptr;
                if (!e_client_refresh_finish(E_CLIENT(sourceObject), result, &error)
                        && ref->store && !wasCancelled(error))
                    ref->store->reportError(QStringLiteral("Refreshing calendar"),
                                            errorText(error));
                g_clear_error(&error);
                if (ref->store)
                    ref->store->refreshFinished(ref->id);
                delete ref;
            },
            ref);
    }
    updateSyncing();
}

void CalendarStore::refreshFinished(const QString &id) {
    m_refreshPending = qMax(0, m_refreshPending - 1);
    // The view signals catch actual changes; the reload covers backends that
    // refetch without announcing anything.
    scheduleReload(id);
    updateSyncing();
}

void CalendarStore::updateSyncing() {
    bool syncing = m_refreshPending > 0;
    for (const Calendar &calendar : std::as_const(m_calendars))
        syncing = syncing || calendar.loading;

    if (m_syncing == syncing)
        return;
    m_syncing = syncing;
    emit syncingChanged();
}

void CalendarStore::setCalendarSelected(const QString &calendarId, bool selected) {
    Calendar *calendar = calendarFor(calendarId);
    if (!calendar)
        return;

    ESourceSelectable *selectable = E_SOURCE_SELECTABLE(
        e_source_get_extension(calendar->source, E_SOURCE_EXTENSION_CALENDAR));
    e_source_selectable_set_selected(selectable, selected);

    writeSource(calendar->source, QStringLiteral("Saving calendar"));

    rebuildCalendarList();
    rebuildEventList();
}

void CalendarStore::writeSource(ESource *source, const QString &context) {
    auto *ref = new StoreRef{this, {}, {}, nullptr, context};
    e_source_write(
        source, m_cancellable,
        [](GObject *sourceObject, GAsyncResult *result, gpointer userData) {
            auto *ref = static_cast<StoreRef *>(userData);
            GError *error = nullptr;
            if (!e_source_write_finish(E_SOURCE(sourceObject), result, &error)
                    && ref->store && !wasCancelled(error))
                ref->store->reportError(ref->context, errorText(error));
            g_clear_error(&error);
            delete ref;
        },
        ref);
}

namespace {
// Payloads for the CalDAV property push and fetch below. Everything in here
// is GLib only: the worker threads must not touch Qt objects.
struct WebdavTask {
    QPointer<CalendarStore> store;
    ESourceRegistry *registry = nullptr;
    ESource *source = nullptr;

    ~WebdavTask() {
        if (source)
            g_object_unref(source);
        if (registry)
            g_object_unref(registry);
    }
};

struct WebdavPush : WebdavTask {
    QByteArray color;       // "#rrggbbff", the form Apple and Google use
    QByteArray displayName; // empty when the collection forbids renaming
};

struct WebdavFetch : WebdavTask {
    QString calendarId;
    QString color;
    QString name;
};

// GDestroyNotify for either payload; instantiated per type so the pointer
// stored as task data is deleted as what it was created as.
template <typename Task>
void webdavTaskFree(gpointer data) {
    delete static_cast<Task *>(data);
}

// A session for the source's server. EDS owns the credentials: for a
// GOA-backed account the lookup returns an empty set and the session fetches
// the OAuth2 token itself. The session keeps its own copy, so they are
// released here; the caller unrefs the session.
EWebDAVSession *openWebdavSession(ESourceRegistry *registry, ESource *source,
                                  GCancellable *cancellable) {
    GError *error = nullptr;
    ESourceCredentialsProvider *provider = e_source_credentials_provider_new(registry);
    ENamedParameters *credentials = nullptr;
    e_source_credentials_provider_lookup_sync(provider, source, cancellable,
                                              &credentials, &error);
    g_clear_error(&error);

    EWebDAVSession *webdav = e_webdav_session_new(source);
    if (credentials) {
        e_soup_session_set_credentials(E_SOUP_SESSION(webdav), credentials);
        e_named_parameters_free(credentials);
    }
    g_object_unref(provider);
    return webdav;
}

void webdavPushThread(GTask *task, gpointer, gpointer taskData, GCancellable *cancellable) {
    auto *push = static_cast<WebdavPush *>(taskData);
    GError *error = nullptr;
    EWebDAVSession *webdav = openWebdavSession(push->registry, push->source, cancellable);

    GSList *changes = nullptr;
    if (!push->color.isEmpty())
        changes = g_slist_prepend(changes, e_webdav_property_change_new_set(
            E_WEBDAV_NS_ICAL, "calendar-color", push->color.constData()));
    if (!push->displayName.isEmpty())
        changes = g_slist_prepend(changes, e_webdav_property_change_new_set(
            E_WEBDAV_NS_DAV, "displayname", push->displayName.constData()));

    const gboolean ok = changes && e_webdav_session_update_properties_sync(
        webdav, nullptr, changes, cancellable, &error);

    g_slist_free_full(changes, e_webdav_property_change_free);
    g_object_unref(webdav);

    if (ok)
        g_task_return_boolean(task, TRUE);
    else if (error)
        g_task_return_error(task, error);
    else
        g_task_return_boolean(task, FALSE);
}
}

namespace {
void webdavFetchThread(GTask *task, gpointer, gpointer taskData, GCancellable *cancellable) {
    auto *fetch = static_cast<WebdavFetch *>(taskData);
    GError *error = nullptr;
    EWebDAVSession *webdav = openWebdavSession(fetch->registry, fetch->source, cancellable);

    GSList *resources = nullptr;
    const gboolean ok = e_webdav_session_list_sync(
        webdav, nullptr, E_WEBDAV_DEPTH_THIS,
        E_WEBDAV_LIST_COLOR | E_WEBDAV_LIST_DISPLAY_NAME, &resources, cancellable, &error);
    if (ok && resources) {
        const auto *resource = static_cast<EWebDAVResource *>(resources->data);
        // Servers answer "#rrggbbaa"; the calendar list carries "#rrggbb".
        if (resource->color && *resource->color)
            fetch->color = QString::fromUtf8(resource->color).left(7).toLower();
        if (resource->display_name && *resource->display_name)
            fetch->name = QString::fromUtf8(resource->display_name);
    }

    g_slist_free_full(resources, e_webdav_resource_free);
    g_object_unref(webdav);
    g_clear_error(&error);

    g_task_return_boolean(task, ok);
}
}

// Whether the source is a CalDAV-style calendar whose server answers WebDAV
// property reads and writes; webcal and friends have nothing to talk to.
bool CalendarStore::isSyncableWebdavCalendar(ESource *source) const {
    if (!m_registry
            || !e_source_has_extension(source, E_SOURCE_EXTENSION_WEBDAV_BACKEND))
        return false;

    ESourceBackend *backend = E_SOURCE_BACKEND(
        e_source_get_extension(source, E_SOURCE_EXTENSION_CALENDAR));
    const QString backendName = QString::fromUtf8(e_source_backend_get_backend_name(backend));
    return backendName == QStringLiteral("caldav") || backendName == QStringLiteral("google");
}

void CalendarStore::fetchWebdavProperties(ESource *source) {
    if (!isSyncableWebdavCalendar(source))
        return;

    auto *fetch = new WebdavFetch;
    fetch->store = this;
    fetch->registry = E_SOURCE_REGISTRY(g_object_ref(m_registry));
    fetch->source = E_SOURCE(g_object_ref(source));
    fetch->calendarId = QString::fromUtf8(e_source_get_uid(source));

    GTask *task = g_task_new(nullptr, m_cancellable,
        [](GObject *, GAsyncResult *result, gpointer) {
            auto *fetch = static_cast<WebdavFetch *>(g_task_get_task_data(G_TASK(result)));
            GError *error = nullptr;
            const bool ok = g_task_propagate_boolean(G_TASK(result), &error);
            g_clear_error(&error);
            if (ok && fetch->store)
                fetch->store->applyWebdavProperties(fetch->calendarId, fetch->name,
                                                    fetch->color);
        }, nullptr);
    g_task_set_task_data(task, fetch, webdavTaskFree<WebdavFetch>);
    g_task_run_in_thread(task, webdavFetchThread);
    g_object_unref(task);
}

void CalendarStore::applyWebdavProperties(const QString &calendarId, const QString &name,
                                          const QString &color) {
    Calendar *calendar = calendarFor(calendarId);
    if (!calendar)
        return;

    ESourceSelectable *selectable = E_SOURCE_SELECTABLE(
        e_source_get_extension(calendar->source, E_SOURCE_EXTENSION_CALENDAR));
    ESourceWebdav *webdav = E_SOURCE_WEBDAV(
        e_source_get_extension(calendar->source, E_SOURCE_EXTENSION_WEBDAV_BACKEND));

    bool changed = false;
    const QString localColor =
        QString::fromUtf8(e_source_selectable_get_color(selectable)).toLower();
    if (!color.isEmpty() && color != localColor) {
        e_source_selectable_set_color(selectable, color.toUtf8().constData());
        e_source_webdav_set_color(webdav, color.toUtf8().constData());
        changed = true;
    }

    const QString localName = QString::fromUtf8(e_source_get_display_name(calendar->source));
    if (!name.isEmpty() && name != localName) {
        e_source_set_display_name(calendar->source, name.toUtf8().constData());
        e_source_webdav_set_display_name(webdav, name.toUtf8().constData());
        changed = true;
    }
    if (!changed)
        return;

    writeSource(calendar->source, QStringLiteral("Updating calendar"));

    rebuildCalendarList();
    rebuildEventList();
}

void CalendarStore::pushWebdavProperties(ESource *source, const QString &name,
                                         const QString &color) {
    if (!isSyncableWebdavCalendar(source))
        return;

    auto *push = new WebdavPush;
    push->store = this;
    push->registry = E_SOURCE_REGISTRY(g_object_ref(m_registry));
    push->source = E_SOURCE(g_object_ref(source));
    if (!color.isEmpty())
        push->color = (color + QStringLiteral("ff")).toUtf8();

    // Renaming is only offered where the account allows it; GOA's Google
    // collection, for one, keeps its calendar names server-side.
    const gchar *parentUid = e_source_get_parent(source);
    bool mayRename = true;
    if (parentUid && *parentUid) {
        ESource *collection = e_source_registry_ref_source(m_registry, parentUid);
        if (collection) {
            if (e_source_has_extension(collection, E_SOURCE_EXTENSION_COLLECTION))
                mayRename = e_source_collection_get_allow_sources_rename(
                    E_SOURCE_COLLECTION(e_source_get_extension(
                        collection, E_SOURCE_EXTENSION_COLLECTION))) == TRUE;
            g_object_unref(collection);
        }
    }
    if (mayRename && !name.isEmpty())
        push->displayName = name.toUtf8();

    GTask *task = g_task_new(nullptr, m_cancellable,
        [](GObject *, GAsyncResult *result, gpointer) {
            auto *push = static_cast<WebdavPush *>(g_task_get_task_data(G_TASK(result)));
            GError *error = nullptr;
            if (!g_task_propagate_boolean(G_TASK(result), &error) && push->store
                    && !wasCancelled(error)) {
                push->store->reportError(QStringLiteral("Saving calendar"),
                    error ? errorText(error)
                          : QStringLiteral("the server refused the change"));
            }
            g_clear_error(&error);
        }, nullptr);
    g_task_set_task_data(task, push, webdavTaskFree<WebdavPush>);
    g_task_run_in_thread(task, webdavPushThread);
    g_object_unref(task);
}

void CalendarStore::setCalendarProperties(const QString &calendarId,
                                          const QString &name, const QString &color) {
    Calendar *calendar = calendarFor(calendarId);
    if (!calendar)
        return;
    if (!e_source_get_writable(calendar->source)) {
        reportError(QStringLiteral("Saving calendar"),
                    QStringLiteral("this calendar cannot be edited here"));
        return;
    }

    const QString trimmed = name.trimmed();
    if (!trimmed.isEmpty())
        e_source_set_display_name(calendar->source, trimmed.toUtf8().constData());
    if (!color.isEmpty()) {
        ESourceSelectable *selectable = E_SOURCE_SELECTABLE(
            e_source_get_extension(calendar->source, E_SOURCE_EXTENSION_CALENDAR));
        e_source_selectable_set_color(selectable, color.toUtf8().constData());
    }

    // A CalDAV source keeps a mirror of the server's own name and color in
    // its WebDAV extension, and the collection backend only pushes a fresh
    // server value down while that mirror still matches what is shown —
    // leaving it behind pins the calendar to our value and silently ends all
    // further syncing. So the mirror moves along, and the change is written
    // to the server too, which is what makes it stick.
    if (e_source_has_extension(calendar->source, E_SOURCE_EXTENSION_WEBDAV_BACKEND)) {
        ESourceWebdav *webdav = E_SOURCE_WEBDAV(
            e_source_get_extension(calendar->source, E_SOURCE_EXTENSION_WEBDAV_BACKEND));
        if (!trimmed.isEmpty())
            e_source_webdav_set_display_name(webdav, trimmed.toUtf8().constData());
        if (!color.isEmpty())
            e_source_webdav_set_color(webdav, color.toUtf8().constData());
        pushWebdavProperties(calendar->source, trimmed, color);
    }

    writeSource(calendar->source, QStringLiteral("Saving calendar"));

    rebuildCalendarList();
    rebuildEventList();
}

ICalComponent *CalendarStore::componentFromEvent(const QVariantMap &event) {
    ICalComponent *component = i_cal_component_new_vevent();
    gchar *uid = e_util_generate_uid();
    i_cal_component_set_uid(component, uid);
    g_free(uid);
    applyEventToComponent(component, event);
    return component;
}

QVariantMap CalendarStore::eventFromComponent(ICalComponent *component) {
    ICalTime *start = i_cal_component_get_dtstart(component);
    ICalTime *end = i_cal_component_get_dtend(component);
    const QVariantMap map = instanceToMap(QString(), component, start, end);
    g_object_unref(start);
    g_object_unref(end);
    return map;
}

// Local echoes: every mutation lands in the cached occurrences right away so
// the interface never waits on the daemon; the view notification that follows
// reloads the authoritative occurrences and replaces these provisional
// entries.
void CalendarStore::echoPatchOccurrences(Calendar &calendar, const QVariantMap &event) {
    const QString uid = event.value(QStringLiteral("uid")).toString();
    const QString rid = event.value(QStringLiteral("recurrenceId")).toString();
    const bool recurring = event.value(QStringLiteral("recurring")).toBool();
    const QString scope =
        event.value(QStringLiteral("scope"), QStringLiteral("this")).toString();

    // Series-wide edits shift every touched occurrence by the same delta the
    // edited one moved, and give them all its new duration.
    const qint64 originalStart = qint64(event.value(QStringLiteral("originalStartMs"),
        event.value(QStringLiteral("startMs"))).toDouble());
    const qint64 delta =
        qint64(event.value(QStringLiteral("startMs")).toDouble()) - originalStart;
    const qint64 duration = qint64(event.value(QStringLiteral("endMs")).toDouble())
        - qint64(event.value(QStringLiteral("startMs")).toDouble());

    for (QVariant &entry : calendar.events) {
        QVariantMap occurrence = entry.toMap();
        if (occurrence.value(QStringLiteral("uid")).toString() != uid)
            continue;

        const bool wholeSeries = recurring && scope != QStringLiteral("this");
        if (recurring && !wholeSeries
                && occurrence.value(QStringLiteral("recurrenceId")).toString() != rid)
            continue;
        if (recurring && scope == QStringLiteral("future")
                && qint64(occurrence.value(QStringLiteral("startMs")).toDouble())
                    < originalStart)
            continue;

        const QStringList keys = {
            QStringLiteral("summary"), QStringLiteral("location"),
            QStringLiteral("description"), QStringLiteral("allDay"),
            QStringLiteral("alarms"),
        };
        for (const QString &key : keys)
            occurrence.insert(key, event.value(key));

        if (wholeSeries) {
            const qint64 shifted =
                qint64(occurrence.value(QStringLiteral("startMs")).toDouble()) + delta;
            occurrence.insert(QStringLiteral("startMs"), double(shifted));
            occurrence.insert(QStringLiteral("endMs"), double(shifted + duration));
        } else {
            occurrence.insert(QStringLiteral("startMs"),
                              event.value(QStringLiteral("startMs")));
            occurrence.insert(QStringLiteral("endMs"),
                              event.value(QStringLiteral("endMs")));
        }
        entry = occurrence;
    }
    rebuildEventList();
}

void CalendarStore::echoRemoveOccurrences(Calendar &calendar, const QString &uid,
                                          const QString &recurrenceId,
                                          const QString &scope) {
    qint64 fromMs = 0;
    if (scope == QStringLiteral("future") && !recurrenceId.isEmpty()) {
        ICalTime *rid = i_cal_time_new_from_string(recurrenceId.toUtf8().constData());
        if (rid) {
            fromMs = timeToMs(rid);
            g_object_unref(rid);
        }
    }

    for (int i = calendar.events.size() - 1; i >= 0; --i) {
        const QVariantMap occurrence = calendar.events.at(i).toMap();
        if (occurrence.value(QStringLiteral("uid")).toString() != uid)
            continue;
        if (scope == QStringLiteral("this")
                && occurrence.value(QStringLiteral("recurrenceId")).toString()
                    != recurrenceId)
            continue;
        if (scope == QStringLiteral("future")
                && qint64(occurrence.value(QStringLiteral("startMs")).toDouble()) < fromMs)
            continue;
        calendar.events.removeAt(i);
    }
    rebuildEventList();
}

// A calendar move is a copy into the target plus a delete from the source.
// The two writes are one change to the user, so the original component is
// fetched first and both halves go into a single history entry — otherwise
// one undo would restore the original while the copy stayed behind.
void CalendarStore::moveEventToCalendar(const QVariantMap &event,
                                        const QString &fromId, const QString &toId) {
    Calendar *source = calendarFor(fromId);
    Calendar *target = calendarFor(toId);
    if (!source || !source->client || !target || !target->client) {
        reportError(QStringLiteral("Moving event"),
                    QStringLiteral("calendar is not available"));
        return;
    }

    auto *ref = new StoreRef{this, fromId, event, nullptr};
    ref->event.insert(QStringLiteral("targetCalendarId"), toId);
    e_cal_client_get_object(
        source->client,
        event.value(QStringLiteral("uid")).toString().toUtf8().constData(),
        nullptr, m_cancellable,
        [](GObject *sourceObject, GAsyncResult *result, gpointer userData) {
            auto *ref = static_cast<StoreRef *>(userData);
            GError *error = nullptr;
            ICalComponent *original = nullptr;
            if (!e_cal_client_get_object_finish(E_CAL_CLIENT(sourceObject), result,
                                                &original, &error)
                    || !original || !ref->store) {
                if (ref->store && !wasCancelled(error))
                    ref->store->reportError(QStringLiteral("Moving event"), errorText(error));
                if (original)
                    g_object_unref(original);
                g_clear_error(&error);
                delete ref;
                return;
            }
            g_clear_error(&error);

            CalendarStore *store = ref->store;
            const QString fromId = ref->id;
            const QString toId =
                ref->event.value(QStringLiteral("targetCalendarId")).toString();
            const QString uid = ref->event.value(QStringLiteral("uid")).toString();

            ICalComponent *copy = componentFromEvent(ref->event);
            const QString copyUid = QString::fromUtf8(i_cal_component_get_uid(copy));

            UndoAction createCopy;
            createCopy.kind = UndoAction::CreateComponent;
            createCopy.calendarId = toId;
            createCopy.ical = componentIcal(copy);
            UndoAction dropOriginal;
            dropOriginal.kind = UndoAction::RemoveComponent;
            dropOriginal.scope = UndoAction::ScopeAll;
            dropOriginal.calendarId = fromId;
            dropOriginal.uid = uid;
            UndoAction restoreOriginal;
            restoreOriginal.kind = UndoAction::CreateComponent;
            restoreOriginal.calendarId = fromId;
            restoreOriginal.ical = componentIcal(original);
            UndoAction dropCopy;
            dropCopy.kind = UndoAction::RemoveComponent;
            dropCopy.scope = UndoAction::ScopeAll;
            dropCopy.calendarId = toId;
            dropCopy.uid = copyUid;

            UndoEntry entry;
            entry.redo = {createCopy, dropOriginal};
            entry.undo = {restoreOriginal, dropCopy};
            store->pushUndoEntry(entry);

            store->createComponentInternal(toId, copy, QStringLiteral("New event"));
            if (Calendar *from = store->calendarFor(fromId))
                store->echoRemoveOccurrences(*from, uid, QString(),
                                             QStringLiteral("all"));
            store->removeEventInternal(fromId, uid, QString(), QStringLiteral("all"));

            g_object_unref(original);
            delete ref;
        },
        ref);
}

void CalendarStore::createEvent(const QVariantMap &event) {
    Calendar *calendar = calendarFor(event.value(QStringLiteral("calendarId")).toString());
    if (!calendar || !calendar->client) {
        reportError(QStringLiteral("New event"), QStringLiteral("calendar is not available"));
        return;
    }

    ICalComponent *component = componentFromEvent(event);

    UndoEntry entry;
    UndoAction redoAction;
    redoAction.kind = UndoAction::CreateComponent;
    redoAction.calendarId = calendar->id;
    redoAction.ical = componentIcal(component);
    UndoAction undoAction;
    undoAction.kind = UndoAction::RemoveComponent;
    undoAction.calendarId = calendar->id;
    undoAction.uid = QString::fromUtf8(i_cal_component_get_uid(component));
    entry.redo = {redoAction};
    entry.undo = {undoAction};
    pushUndoEntry(entry);

    createComponentInternal(calendar->id, component, QStringLiteral("New event"));
}

// The write half of createEvent: echo it locally, then hand it to the
// backend. Records no history of its own, so callers that compose several
// writes into one user-visible change can push a single entry. Callers that
// echoed already — or must not, because a recurring master cannot stand in
// for its series — pass echoLocally false.
void CalendarStore::createComponentInternal(const QString &calendarId,
                                            ICalComponent *component,
                                            const QString &context, bool echoLocally) {
    Calendar *calendar = calendarFor(calendarId);
    if (!calendar || !calendar->client) {
        g_object_unref(component);
        return;
    }

    if (echoLocally) {
        QVariantMap echo = eventFromComponent(component);
        echo.insert(QStringLiteral("calendarId"), calendarId);
        calendar->events.append(echo);
        rebuildEventList();
    }

    auto *ref = new StoreRef{this, calendarId, {}, component, context};
    e_cal_client_create_object(
        calendar->client, component, E_CAL_OPERATION_FLAG_NONE, m_cancellable,
        [](GObject *sourceObject, GAsyncResult *result, gpointer userData) {
            auto *ref = static_cast<StoreRef *>(userData);
            GError *error = nullptr;
            gchar *uid = nullptr;
            if (!e_cal_client_create_object_finish(E_CAL_CLIENT(sourceObject), result,
                                                   &uid, &error)
                    && ref->store && !wasCancelled(error))
                ref->store->reportError(ref->context, errorText(error));
            g_free(uid);
            g_clear_error(&error);
            delete ref;
        },
        ref);
}

// The matching modify half, shared by edits and history replays. Takes
// ownership of the component; `store` may be gone mid-flight, which only
// mutes the error report.
void CalendarStore::modifyComponentInternal(CalendarStore *store, ECalClient *client,
                                            ICalComponent *component, const QString &scope,
                                            const QString &context) {
    auto *ref = new StoreRef{store, {}, {}, component, context};
    e_cal_client_modify_object(
        client, component, modTypeForScope(scope), E_CAL_OPERATION_FLAG_NONE,
        store ? store->m_cancellable : nullptr,
        [](GObject *sourceObject, GAsyncResult *result, gpointer userData) {
            auto *ref = static_cast<StoreRef *>(userData);
            GError *error = nullptr;
            if (!e_cal_client_modify_object_finish(E_CAL_CLIENT(sourceObject), result,
                                                   &error)
                    && ref->store && !wasCancelled(error))
                ref->store->reportError(ref->context, errorText(error));
            g_clear_error(&error);
            delete ref;
        },
        ref);
}

void CalendarStore::updateEvent(const QVariantMap &event) {
    const QString targetId = event.value(QStringLiteral("calendarId")).toString();
    const QString currentId =
        event.value(QStringLiteral("originalCalendarId"), targetId).toString();
    const QString uid = event.value(QStringLiteral("uid")).toString();
    const bool recurring = event.value(QStringLiteral("recurring")).toBool();

    // Moving to another calendar is a copy-then-delete; recurring events stay
    // put because a lone exception must not leave its series behind.
    if (targetId != currentId && !recurring) {
        moveEventToCalendar(event, currentId, targetId);
        return;
    }

    Calendar *calendar = calendarFor(currentId);
    if (!calendar || !calendar->client) {
        reportError(QStringLiteral("Saving event"), QStringLiteral("calendar is not available"));
        return;
    }

    echoPatchOccurrences(*calendar, event);

    auto *ref = new StoreRef{this, currentId, event, nullptr};
    e_cal_client_get_object(
        calendar->client, uid.toUtf8().constData(), nullptr, m_cancellable,
        [](GObject *sourceObject, GAsyncResult *result, gpointer userData) {
            auto *ref = static_cast<StoreRef *>(userData);
            auto *client = E_CAL_CLIENT(sourceObject);
            GError *error = nullptr;
            ICalComponent *master = nullptr;
            if (!e_cal_client_get_object_finish(client, result, &master, &error)) {
                if (ref->store && !wasCancelled(error))
                    ref->store->reportError(QStringLiteral("Saving event"), errorText(error));
                g_clear_error(&error);
                delete ref;
                return;
            }

            const QString scope = ref->event
                .value(QStringLiteral("scope"), QStringLiteral("this")).toString();
            const bool recurring =
                ref->event.value(QStringLiteral("recurring")).toBool();
            const QString masterBefore = componentIcal(master);

            ICalComponent *modified = master;
            QString beforeIcal = masterBefore;
            UndoAction::Scope undoScope = UndoAction::ScopeThis;
            UndoAction::Scope redoScope = UndoAction::ScopeThis;

            if (recurring && scope == QStringLiteral("all")) {
                // The whole series moves by the delta the edited occurrence
                // moved, and every occurrence takes its new duration.
                ICalTime *seriesStart = i_cal_component_get_dtstart(master);
                const qint64 seriesStartMs = seriesStart ? timeToMs(seriesStart) : 0;
                if (seriesStart)
                    g_object_unref(seriesStart);
                const qint64 newStart =
                    qint64(ref->event.value(QStringLiteral("startMs")).toDouble());
                const qint64 originalStart = qint64(ref->event
                    .value(QStringLiteral("originalStartMs"),
                           ref->event.value(QStringLiteral("startMs"))).toDouble());
                const qint64 duration =
                    qint64(ref->event.value(QStringLiteral("endMs")).toDouble())
                    - newStart;

                QVariantMap adjusted = ref->event;
                const qint64 shifted = seriesStartMs + (newStart - originalStart);
                adjusted.insert(QStringLiteral("startMs"), double(shifted));
                adjusted.insert(QStringLiteral("endMs"), double(shifted + duration));
                applyEventToComponent(master, adjusted);
                undoScope = UndoAction::ScopeAll;
                redoScope = UndoAction::ScopeAll;
            } else if (recurring) {
                // "this" detaches one exception; "future" splits the series
                // at this occurrence. Both hand the backend an instance
                // component carrying the RECURRENCE-ID.
                ICalTime *rid = i_cal_time_new_from_string(
                    ref->event.value(QStringLiteral("recurrenceId")).toString()
                        .toUtf8().constData());
                ICalComponent *instance = e_cal_util_construct_instance(master, rid);
                g_object_unref(rid);
                if (!instance) {
                    // Without a valid instance the only component at hand is
                    // the master, and writing this occurrence's times into
                    // that would move the entire series.
                    if (ref->store)
                        ref->store->reportError(QStringLiteral("Saving event"),
                            QStringLiteral("this occurrence is no longer part of the series"));
                    g_object_unref(master);
                    delete ref;
                    return;
                }
                g_object_unref(master);
                modified = instance;
                // "future" is the one case where the backend needs the rules
                // on the component, to build the split series from them.
                if (scope != QStringLiteral("future"))
                    CalendarStore::stripSeriesRules(instance);
                if (scope == QStringLiteral("future")) {
                    // Undoing a split restores the captured pre-split master.
                    undoScope = UndoAction::ScopeAll;
                    redoScope = UndoAction::ScopeFuture;
                } else {
                    beforeIcal = componentIcal(modified);
                }
                applyEventToComponent(modified, ref->event);
            } else {
                applyEventToComponent(master, ref->event);
            }

            if (ref->store) {
                UndoEntry entry;
                UndoAction undoAction;
                undoAction.kind = UndoAction::ModifyComponent;
                undoAction.scope = undoScope;
                undoAction.calendarId = ref->id;
                undoAction.ical = beforeIcal;
                UndoAction redoAction;
                redoAction.kind = UndoAction::ModifyComponent;
                redoAction.scope = redoScope;
                redoAction.calendarId = ref->id;
                redoAction.ical = componentIcal(modified);
                entry.undo = {undoAction};
                entry.redo = {redoAction};
                ref->store->pushUndoEntry(entry);
            }

            // The backend's mod type follows the redo scope; the two were
            // chosen together above.
            modifyComponentInternal(ref->store, client, modified,
                                    scopeToString(redoScope),
                                    QStringLiteral("Saving event"));
            delete ref;
        },
        ref);
}

void CalendarStore::removeEvent(const QString &calendarId, const QString &uid,
                                const QString &recurrenceId, const QString &scope) {
    Calendar *calendar = calendarFor(calendarId);
    if (!calendar || !calendar->client) {
        reportError(QStringLiteral("Deleting event"),
                    QStringLiteral("calendar is not available"));
        return;
    }

    // Capture the full master component first, so undo can bring back the
    // entire series — rules, alarms and all. Partial deletions ("this",
    // "future") undo by writing the pre-delete master back, which drops the
    // EXDATE or restores the shortened rule.
    auto *ref = new StoreRef{this, calendarId, {}, nullptr};
    ref->event.insert(QStringLiteral("uid"), uid);
    ref->event.insert(QStringLiteral("recurrenceId"), recurrenceId);
    ref->event.insert(QStringLiteral("scope"), scope);
    e_cal_client_get_object(
        calendar->client, uid.toUtf8().constData(), nullptr, m_cancellable,
        [](GObject *sourceObject, GAsyncResult *result, gpointer userData) {
            auto *ref = static_cast<StoreRef *>(userData);
            GError *error = nullptr;
            ICalComponent *master = nullptr;
            if (e_cal_client_get_object_finish(E_CAL_CLIENT(sourceObject), result,
                                               &master, &error)
                    && master && ref->store) {
                const QString scope =
                    ref->event.value(QStringLiteral("scope")).toString();
                UndoEntry entry;
                UndoAction redoAction;
                redoAction.kind = UndoAction::RemoveComponent;
                redoAction.scope = scopeFromString(scope);
                redoAction.calendarId = ref->id;
                redoAction.uid = ref->event.value(QStringLiteral("uid")).toString();
                redoAction.recurrenceId =
                    ref->event.value(QStringLiteral("recurrenceId")).toString();
                UndoAction undoAction;
                undoAction.kind = scope == QStringLiteral("all")
                    ? UndoAction::CreateComponent : UndoAction::ModifyComponent;
                undoAction.scope = UndoAction::ScopeAll;
                undoAction.calendarId = ref->id;
                undoAction.ical = componentIcal(master);
                entry.redo = {redoAction};
                entry.undo = {undoAction};
                ref->store->pushUndoEntry(entry);
            }
            if (master)
                g_object_unref(master);
            g_clear_error(&error);
            delete ref;
        },
        ref);

    echoRemoveOccurrences(*calendar, uid, recurrenceId, scope);
    removeEventInternal(calendarId, uid, recurrenceId, scope);
}

void CalendarStore::removeEventInternal(const QString &calendarId, const QString &uid,
                                        const QString &recurrenceId,
                                        const QString &scope) {
    Calendar *calendar = calendarFor(calendarId);
    if (!calendar || !calendar->client)
        return;

    const bool wholeSeries = scope == QStringLiteral("all");
    auto *ref = new StoreRef{this, calendarId, {}, nullptr};
    e_cal_client_remove_object(
        calendar->client, uid.toUtf8().constData(),
        wholeSeries ? nullptr : recurrenceId.toUtf8().constData(),
        modTypeForScope(scope),
        E_CAL_OPERATION_FLAG_NONE, m_cancellable,
        [](GObject *sourceObject, GAsyncResult *result, gpointer userData) {
            auto *ref = static_cast<StoreRef *>(userData);
            GError *error = nullptr;
            if (!e_cal_client_remove_object_finish(E_CAL_CLIENT(sourceObject), result, &error)
                    && ref->store && !wasCancelled(error))
                ref->store->reportError(QStringLiteral("Deleting event"), errorText(error));
            g_clear_error(&error);
            delete ref;
        },
        ref);
}

CalendarStore::UndoAction::Scope CalendarStore::scopeFromString(const QString &scope) {
    if (scope == QStringLiteral("this"))
        return UndoAction::ScopeThis;
    return scope == QStringLiteral("future") ? UndoAction::ScopeFuture
                                             : UndoAction::ScopeAll;
}

QString CalendarStore::scopeToString(UndoAction::Scope scope) {
    if (scope == UndoAction::ScopeThis)
        return QStringLiteral("this");
    return scope == UndoAction::ScopeFuture ? QStringLiteral("future")
                                            : QStringLiteral("all");
}

void CalendarStore::pushUndoEntry(const UndoEntry &entry) {
    if (m_replaying)
        return;
    m_undoStack.append(entry);
    while (m_undoStack.size() > 100)
        m_undoStack.removeFirst();
    m_redoStack.clear();
    emit undoChanged();
}

void CalendarStore::undo() {
    if (m_undoStack.isEmpty())
        return;
    const UndoEntry entry = m_undoStack.takeLast();
    m_replaying = true;
    applyUndoActions(entry.undo);
    m_replaying = false;
    m_redoStack.append(entry);
    emit undoChanged();
}

void CalendarStore::redo() {
    if (m_redoStack.isEmpty())
        return;
    const UndoEntry entry = m_redoStack.takeLast();
    m_replaying = true;
    applyUndoActions(entry.redo);
    m_replaying = false;
    m_undoStack.append(entry);
    emit undoChanged();
}

void CalendarStore::applyUndoActions(const QList<UndoAction> &actions) {
    for (const UndoAction &action : actions) {
        Calendar *calendar = calendarFor(action.calendarId);
        if (!calendar || !calendar->client) {
            reportError(QStringLiteral("Undo"),
                        QStringLiteral("calendar is not available"));
            continue;
        }

        const QString scopeText = scopeToString(action.scope);

        if (action.kind == UndoAction::RemoveComponent) {
            echoRemoveOccurrences(*calendar, action.uid, action.recurrenceId, scopeText);
            removeEventInternal(action.calendarId, action.uid, action.recurrenceId,
                                scopeText);
            continue;
        }

        ICalComponent *component =
            i_cal_component_new_from_string(action.ical.toUtf8().constData());
        if (!component) {
            reportError(QStringLiteral("Undo"),
                        QStringLiteral("could not rebuild the event"));
            continue;
        }

        // Instant echo; recurring masters are left to the reload, since a
        // single occurrence map cannot stand in for a series.
        if (!e_cal_util_component_has_recurrences(component)) {
            QVariantMap echo = eventFromComponent(component);
            echo.insert(QStringLiteral("calendarId"), calendar->id);
            if (action.kind == UndoAction::CreateComponent) {
                calendar->events.append(echo);
                rebuildEventList();
            } else {
                echoPatchOccurrences(*calendar, echo);
            }
        }

        if (action.kind == UndoAction::CreateComponent)
            createComponentInternal(action.calendarId, component,
                                    QStringLiteral("Undo"), false);
        else
            modifyComponentInternal(this, calendar->client, component, scopeText,
                                    QStringLiteral("Undo"));
    }
}

// The account a calendar belongs to — the display name of its topmost parent
// collection ("On This Computer" for local sources, the account name for
// CalDAV/Google/… collections). Groups the sidebar the way Apple Calendar
// groups by account.
QString CalendarStore::groupNameFor(ESource *source) const {
    QString name;
    ESource *node = E_SOURCE(g_object_ref(source));
    while (m_registry) {
        const gchar *parentUid = e_source_get_parent(node);
        if (!parentUid || !*parentUid)
            break;
        ESource *parent = e_source_registry_ref_source(m_registry, parentUid);
        if (!parent)
            break;
        name = QString::fromUtf8(e_source_get_display_name(parent));
        g_object_unref(node);
        node = parent;
    }
    g_object_unref(node);
    return name.isEmpty() ? tr("Other") : name;
}

QVariantMap CalendarStore::calendarEntry(const Calendar &calendar,
                                         const QString &group) const {
    ESourceSelectable *selectable = E_SOURCE_SELECTABLE(
        e_source_get_extension(calendar.source, E_SOURCE_EXTENSION_CALENDAR));
    const gchar *color = e_source_selectable_get_color(selectable);

    QVariantMap map;
    map.insert(QStringLiteral("id"), calendar.id);
    map.insert(QStringLiteral("name"),
               QString::fromUtf8(e_source_get_display_name(calendar.source)));
    map.insert(QStringLiteral("group"), group);
    map.insert(QStringLiteral("color"), color ? QString::fromUtf8(color) : QString());
    map.insert(QStringLiteral("selected"),
               e_source_selectable_get_selected(selectable) == TRUE);
    map.insert(QStringLiteral("readOnly"),
               !calendar.client
                   || e_client_is_readonly(E_CLIENT(calendar.client)) == TRUE);
    // Whether the source's own metadata (name, color) can be edited — a
    // calendar can be read-only for events yet renamable, and vice versa.
    map.insert(QStringLiteral("writable"),
               e_source_get_writable(calendar.source) == TRUE);
    return map;
}

void CalendarStore::rebuildCalendarList() {
    // The order is rederived from the calendar set every time; group names
    // are resolved once per calendar up front, since each lookup walks the
    // parent chain through the registry — too heavy for a sort comparator.
    QStringList order = m_calendars.keys();
    QHash<QString, QString> groups;
    groups.reserve(order.size());
    for (const QString &id : std::as_const(order))
        groups.insert(id, groupNameFor(m_calendars[id].source));

    // Grouped by account first so the sidebar's sections come out contiguous.
    std::sort(order.begin(), order.end(),
              [this, &groups](const QString &a, const QString &b) {
        const int byGroup =
            QString::compare(groups.value(a), groups.value(b), Qt::CaseInsensitive);
        if (byGroup != 0)
            return byGroup < 0;
        const QString nameA = QString::fromUtf8(e_source_get_display_name(m_calendars[a].source));
        const QString nameB = QString::fromUtf8(e_source_get_display_name(m_calendars[b].source));
        const int byName = QString::compare(nameA, nameB, Qt::CaseInsensitive);
        return byName != 0 ? byName < 0 : a < b;
    });
    m_calendarOrder = order;

    m_calendarList.clear();
    for (const QString &id : std::as_const(m_calendarOrder))
        m_calendarList.append(calendarEntry(m_calendars[id], groups.value(id)));
    emit calendarsChanged();
}

void CalendarStore::rebuildEventList() {
    // A direct rebuild satisfies any coalesced one still pending.
    m_rebuildTimer.stop();
    QElapsedTimer rebuildTimer;
    rebuildTimer.start();

    // Sorted on keys extracted up front: toMap() inside the comparator would
    // detach a fresh map copy on every probe.
    QList<std::pair<double, QVariant>> keyed;
    for (const QString &id : std::as_const(m_calendarOrder)) {
        Calendar &calendar = m_calendars[id];
        ESourceSelectable *selectable = E_SOURCE_SELECTABLE(
            e_source_get_extension(calendar.source, E_SOURCE_EXTENSION_CALENDAR));
        calendar.selectedInEventList =
            e_source_selectable_get_selected(selectable) == TRUE;
        if (!calendar.selectedInEventList)
            continue;
        keyed.reserve(keyed.size() + calendar.events.size());
        for (const QVariant &event : std::as_const(calendar.events))
            keyed.emplace_back(
                event.toMap().value(QStringLiteral("startMs")).toDouble(), event);
    }
    std::sort(keyed.begin(), keyed.end(),
              [](const std::pair<double, QVariant> &a,
                 const std::pair<double, QVariant> &b) {
        return a.first < b.first;
    });

    QVariantList events;
    events.reserve(keyed.size());
    for (auto &entry : keyed)
        events.append(std::move(entry.second));

    m_eventList = events;
    PERF("rebuildEventList " + QString::number(events.size()) + " events in "
         + QString::number(rebuildTimer.elapsed()) + "ms");
    emit eventsChanged();
}

void CalendarStore::search(const QString &text) {
    const QString needle = text.trimmed();
    if (needle.isEmpty()) {
        clearSearch();
        return;
    }

    // A new query invalidates whatever is still in flight; late replies are
    // matched against the generation and dropped.
    const int generation = ++m_searchGeneration;
    m_searchCollect.clear();
    m_searchPending = 0;

    // gnome-calendar's search window: eight months back, six ahead — and it
    // matches real occurrences inside it, so recurring events surface at
    // their actual dates rather than as one series master.
    const QDateTime now = QDateTime::currentDateTime();
    const time_t rangeStart = now.addMonths(-8).toSecsSinceEpoch();
    const time_t rangeEnd = now.addMonths(6).toSecsSinceEpoch();

    for (const QString &id : std::as_const(m_calendarOrder)) {
        Calendar *calendar = calendarFor(id);
        if (!calendar || !calendar->client)
            continue;

        ++m_searchPending;
        auto *collect = new InstanceCollect{this, id, {}, needle, generation};
        generateInstances(
            calendar->client, rangeStart, rangeEnd, m_cancellable,
            [](ICalComponent *component, ICalTime *instanceStart, ICalTime *instanceEnd,
               gpointer userData, GCancellable *, GError **) -> gboolean {
                auto *collect = static_cast<InstanceCollect *>(userData);
                const auto matches = [collect](const gchar *value) {
                    return value && QString::fromUtf8(value)
                        .contains(collect->needle, Qt::CaseInsensitive);
                };
                if (matches(i_cal_component_get_summary(component))
                        || matches(i_cal_component_get_location(component)))
                    collect->instances.append(instanceToMap(
                        collect->id, component, instanceStart, instanceEnd));
                return TRUE;
            },
            collect, instanceRunDone);
    }

    if (m_searchPending == 0) {
        m_searchResults.clear();
        emit searchResultsChanged();
    }
}

void CalendarStore::searchResultsArrived(int generation, const QVariantList &results) {
    if (generation != m_searchGeneration)
        return;

    m_searchCollect.append(results);
    if (--m_searchPending > 0)
        return;

    QHash<QString, QString> calendarNames;
    for (const QString &id : std::as_const(m_calendarOrder)) {
        if (Calendar *calendar = calendarFor(id))
            calendarNames.insert(
                id, QString::fromUtf8(e_source_get_display_name(calendar->source)));
    }

    // gnome-calendar's ordering: the closer to now, the higher — anything
    // upcoming beats anything past, nearer beats farther on both sides.
    // Ties fall back to the calendar name, descending, like gcal does.
    const qint64 nowMs = QDateTime::currentMSecsSinceEpoch();
    std::sort(m_searchCollect.begin(), m_searchCollect.end(),
              [nowMs, &calendarNames](const QVariant &a, const QVariant &b) {
        const QVariantMap mapA = a.toMap();
        const QVariantMap mapB = b.toMap();
        const qint64 diffA = qint64(mapA.value(QStringLiteral("startMs")).toDouble()) - nowMs;
        const qint64 diffB = qint64(mapB.value(QStringLiteral("startMs")).toDouble()) - nowMs;
        if (diffA != diffB) {
            if (diffA == 0)
                return true;
            if (diffB == 0)
                return false;
            if (diffA > 0 && diffB < 0)
                return true;
            if (diffA < 0 && diffB > 0)
                return false;
            return diffA < 0 ? qAbs(diffA) < qAbs(diffB) : diffA < diffB;
        }
        const QString nameA =
            calendarNames.value(mapA.value(QStringLiteral("calendarId")).toString());
        const QString nameB =
            calendarNames.value(mapB.value(QStringLiteral("calendarId")).toString());
        return QString::compare(nameB, nameA) < 0;
    });
    while (m_searchCollect.size() > 128)
        m_searchCollect.removeLast();

    m_searchResults = m_searchCollect;
    m_searchCollect = QVariantList();
    emit searchResultsChanged();
}

void CalendarStore::clearSearch() {
    ++m_searchGeneration;
    m_searchPending = 0;
    m_searchCollect.clear();
    if (m_searchResults.isEmpty())
        return;
    m_searchResults.clear();
    emit searchResultsChanged();
}

void CalendarStore::reportError(const QString &context, const QString &message) {
    qWarning().noquote() << context << "failed:" << message;
    m_lastError = context + QStringLiteral(": ") + message;
    emit lastErrorChanged();
}

CalendarStore::Calendar *CalendarStore::calendarFor(const QString &id) {
    const auto it = m_calendars.find(id);
    return it == m_calendars.end() ? nullptr : &it.value();
}
