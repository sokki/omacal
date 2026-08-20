#pragma once

#include <QDateTime>
#include <QHash>
#include <QObject>
#include <QSet>
#include <QString>
#include <QStringList>
#include <QTimer>
#include <QVariantList>
#include <QVariantMap>

// Opaque GLib/EDS handles; the real headers stay out of here so Qt's signal
// macros and GObject headers never meet.
typedef struct _ESourceRegistry ESourceRegistry;
typedef struct _ECalClient ECalClient;
typedef struct _ECalClientView ECalClientView;
typedef struct _ESource ESource;
typedef struct _GCancellable GCancellable;
typedef struct _ICalComponent ICalComponent;

// The bridge between QML and evolution-data-server. Lists the calendars known
// to the source registry, expands event occurrences for the visible date
// range, and writes creations, edits, and removals back through ECalClient.
//
// Everything runs asynchronously on the GLib main context that Qt's event
// dispatcher drives, so the interface never blocks on the calendar daemon.
class CalendarStore : public QObject {
    Q_OBJECT
    Q_PROPERTY(QVariantList calendars READ calendars NOTIFY calendarsChanged)
    Q_PROPERTY(QVariantList events READ events NOTIFY eventsChanged)
    Q_PROPERTY(bool ready READ ready NOTIFY readyChanged)
    Q_PROPERTY(bool syncing READ syncing NOTIFY syncingChanged)
    Q_PROPERTY(bool canUndo READ canUndo NOTIFY undoChanged)
    Q_PROPERTY(bool canRedo READ canRedo NOTIFY undoChanged)
    Q_PROPERTY(QVariantList searchResults READ searchResults NOTIFY searchResultsChanged)
    Q_PROPERTY(QString lastError READ lastError NOTIFY lastErrorChanged)

public:
    explicit CalendarStore(QObject *parent = nullptr);
    ~CalendarStore() override;

    QVariantList calendars() const { return m_calendarList; }
    QVariantList events() const { return m_eventList; }
    bool ready() const { return m_ready; }
    bool syncing() const { return m_syncing; }
    bool canUndo() const { return !m_undoStack.isEmpty(); }
    bool canRedo() const { return !m_redoStack.isEmpty(); }
    QString lastError() const { return m_lastError; }

    // Walk the mutation history. Each user-visible change (create, edit,
    // move, resize, delete) is one step.
    Q_INVOKABLE void undo();
    Q_INVOKABLE void redo();

    QVariantList searchResults() const { return m_searchResults; }

    // Free-text search over every connected calendar, all time — backed by
    // the daemon's own index, not the loaded occurrence window. Recurring
    // events surface once, at their series start.
    Q_INVOKABLE void search(const QString &text);
    Q_INVOKABLE void clearSearch();

    // Ask every backend that supports it (CalDAV, Google, …) to refetch from
    // its server; local calendars just reload. Progress shows via `syncing`.
    Q_INVOKABLE void refreshAll();

    // The date window the interface currently shows; occurrences are loaded
    // for it (padded by a day on each side for timezone slack).
    Q_INVOKABLE void setVisibleRange(double startMs, double endMs);

    // Show or hide a calendar. Persisted into the source itself, so the
    // choice is shared with Evolution and GNOME Calendar.
    Q_INVOKABLE void setCalendarSelected(const QString &calendarId, bool selected);

    // Rename and recolor a calendar. Both live on the EDS source, so the
    // change is shared with every other client; sources whose metadata is
    // managed elsewhere (`writable` false in the calendar entry) refuse it.
    Q_INVOKABLE void setCalendarProperties(const QString &calendarId,
                                           const QString &name, const QString &color);

    // Event maps carry: calendarId, uid, recurrenceId, summary, location,
    // description, startMs, endMs, allDay, recurring, alarms, rrule. Updates
    // to recurring events add "scope": "this" (default), "future", or "all",
    // plus "originalStartMs" (the unedited occurrence start) so series-wide
    // time changes shift by the right delta. Removals take the same scopes.
    Q_INVOKABLE void createEvent(const QVariantMap &event);
    Q_INVOKABLE void updateEvent(const QVariantMap &event);
    Q_INVOKABLE void removeEvent(const QString &calendarId, const QString &uid,
                                 const QString &recurrenceId, const QString &scope);

    // A fresh VEVENT from an event map; exposed for the tests. The caller
    // owns the returned component.
    static ICalComponent *componentFromEvent(const QVariantMap &event);
    // The map view of a plain (non-expanded) VEVENT; exposed for the tests.
    static QVariantMap eventFromComponent(ICalComponent *component);
    // Writes an event map's fields (summary, times, alert, …) into an
    // existing VEVENT; exposed for the tests.
    static void applyEventToComponent(ICalComponent *component, const QVariantMap &event);
    // Turns a clone of a series master into a lone exception by dropping the
    // recurrence properties it must not repeat; exposed for the tests.
    static void stripSeriesRules(ICalComponent *component);

signals:
    void calendarsChanged();
    void eventsChanged();
    void readyChanged();
    void syncingChanged();
    void undoChanged();
    void searchResultsChanged();
    void lastErrorChanged();

private:
    struct Calendar {
        QString id;
        ESource *source = nullptr;
        ECalClient *client = nullptr;
        ECalClientView *view = nullptr;
        QVariantList events;
        bool loading = false;
        bool reloadQueued = false;
        bool selectedInEventList = false; // the flag the built event list reflects
    };

    // One reversible step of the mutation history. Components travel as
    // serialized iCalendar so a deleted recurring series (rules, alarms and
    // all) can be recreated verbatim.
    struct UndoAction {
        enum Kind { CreateComponent, ModifyComponent, RemoveComponent };
        enum Scope { ScopeThis, ScopeAll, ScopeFuture };
        Kind kind = CreateComponent;
        Scope scope = ScopeThis; // Modify/Remove: which occurrences
        QString calendarId;
        QString ical;        // CreateComponent / ModifyComponent payload
        QString uid;         // RemoveComponent target
        QString recurrenceId;
    };
    struct UndoEntry {
        QList<UndoAction> undo;
        QList<UndoAction> redo;
    };

    void registryReady(ESourceRegistry *registry);
    void clientConnected(const QString &id, ECalClient *client);
    void viewReady(const QString &id, ECalClientView *view);
    void viewChanged(ECalClientView *view);
    void instancesLoaded(const QString &id, const QVariantList &instances);
    void addSource(ESource *source);
    void removeSource(const QString &id);
    void refreshSourceEntry(ESource *source);
    void connectClient(Calendar &calendar);
    void reloadCalendar(const QString &id);
    void scheduleReload(const QString &id);
    void rebuildCalendarList();
    void rebuildEventList();
    QString groupNameFor(ESource *source) const;
    void refreshFinished(const QString &id);
    void updateSyncing();
    void reportError(const QString &context, const QString &message);
    // Persist source metadata; a failure reports under the caller's context.
    void writeSource(ESource *source, const QString &context);
    // A CalDAV-style calendar whose server answers WebDAV property reads and
    // writes; webcal and friends have nothing to talk to.
    bool isSyncableWebdavCalendar(ESource *source) const;
    QVariantMap calendarEntry(const Calendar &calendar, const QString &group) const;
    Calendar *calendarFor(const QString &id);
    void echoPatchOccurrences(Calendar &calendar, const QVariantMap &event);
    void echoRemoveOccurrences(Calendar &calendar, const QString &uid,
                               const QString &recurrenceId, const QString &scope);
    // Send a renamed/recolored calendar to its CalDAV server, so the change
    // reaches Google, Apple, and every other client rather than staying a
    // local override. Runs on a worker thread; EDS supplies the credentials.
    void pushWebdavProperties(ESource *source, const QString &name, const QString &color);
    // The other direction: read the server's own name and color and adopt
    // them. EDS only does this while re-discovering a whole account, so a
    // colour changed in Google would otherwise never reach us.
    void fetchWebdavProperties(ESource *source);
    void applyWebdavProperties(const QString &calendarId, const QString &name,
                               const QString &color);
    void moveEventToCalendar(const QVariantMap &event, const QString &fromId,
                             const QString &toId);
    void createComponentInternal(const QString &calendarId, ICalComponent *component,
                                 const QString &context, bool echoLocally = true);
    // The matching modify half. Takes ownership of the component; `store`
    // may be null when the store died mid-flight, which only mutes the
    // error report.
    static void modifyComponentInternal(CalendarStore *store, ECalClient *client,
                                        ICalComponent *component, const QString &scope,
                                        const QString &context);
    // "this"/"future"/"all", as QML spells recurrence scopes.
    static UndoAction::Scope scopeFromString(const QString &scope);
    static QString scopeToString(UndoAction::Scope scope);
    // GDestroyNotify of both instance runs: marshals an InstanceCollect back
    // to the store's thread.
    static void instanceRunDone(void *data);
    void pushUndoEntry(const UndoEntry &entry);
    void applyUndoActions(const QList<UndoAction> &actions);
    void searchResultsArrived(int generation, const QVariantList &results);
    void removeEventInternal(const QString &calendarId, const QString &uid,
                             const QString &recurrenceId, const QString &scope);

    ESourceRegistry *m_registry = nullptr;
    GCancellable *m_cancellable = nullptr;
    QHash<QString, Calendar> m_calendars;
    // Sorted ids, rederived from m_calendars on every rebuildCalendarList();
    // cached because every list walk shares this display order.
    QStringList m_calendarOrder;
    QVariantList m_calendarList;
    QVariantList m_eventList;
    QTimer m_reloadTimer;
    QTimer m_rebuildTimer; // coalesces event-list rebuilds within a burst
    QSet<QString> m_pendingReloads;
    QDateTime m_rangeStart;
    QDateTime m_rangeEnd;
    bool m_ready = false;
    bool m_syncing = false;
    int m_refreshPending = 0;
    QList<UndoEntry> m_undoStack;
    QList<UndoEntry> m_redoStack;
    bool m_replaying = false;
    QVariantList m_searchResults;
    QVariantList m_searchCollect;
    int m_searchGeneration = 0;
    int m_searchPending = 0;
    QString m_lastError;
    ulong m_registryHandlers[3] = {0, 0, 0};
};
