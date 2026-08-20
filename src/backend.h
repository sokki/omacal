#pragma once

#include <QFileSystemWatcher>
#include <QHash>
#include <QObject>
#include <QString>
#include <QStringList>
#include <QVariantMap>

// App-level state shared with QML: the omarchy theme colors, dark mode, the
// desktop text scale, and the remembered window geometry and view mode.
class Backend : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool darkMode READ darkMode WRITE setDarkMode NOTIFY darkModeChanged)
    Q_PROPERTY(qreal textScale READ textScale WRITE setTextScale NOTIFY textScaleChanged)
    Q_PROPERTY(QString themeBackground READ themeBackground NOTIFY themeColorsChanged)
    Q_PROPERTY(QString themeForeground READ themeForeground NOTIFY themeColorsChanged)
    Q_PROPERTY(QString themeAccent READ themeAccent NOTIFY themeColorsChanged)
    Q_PROPERTY(QString themeDanger READ themeDanger NOTIFY themeColorsChanged)
    Q_PROPERTY(QStringList themePalette READ themePalette NOTIFY themeColorsChanged)
    Q_PROPERTY(QString viewMode READ viewMode WRITE setViewMode NOTIFY viewModeChanged)
    Q_PROPERTY(QString lastCalendarId READ lastCalendarId WRITE setLastCalendarId
               NOTIFY lastCalendarIdChanged)

public:
    explicit Backend(QObject *parent = nullptr);

    bool darkMode() const { return m_darkMode; }
    void setDarkMode(bool darkMode);
    qreal textScale() const { return m_textScale; }
    void setTextScale(qreal textScale);
    QString themeBackground() const { return m_themeBackground; }
    QString themeForeground() const { return m_themeForeground; }
    QString themeAccent() const { return m_themeAccent; }
    QString themeDanger() const { return m_themeDanger; }
    QStringList themePalette() const { return m_themePalette; }
    QString viewMode() const { return m_viewMode; }
    void setViewMode(const QString &viewMode);

    // The calendar the last event was filed under, so the next new event
    // starts there again after a restart.
    QString lastCalendarId() const { return m_lastCalendarId; }
    void setLastCalendarId(const QString &calendarId);

    // The key/value pairs of an omarchy colors.toml, with quotes stripped.
    // Separated out so the parsing stays testable without a real theme.
    static QHash<QString, QString> colorsFromFile(const QString &path);

    Q_INVOKABLE QVariantMap windowGeometry() const;
    Q_INVOKABLE void saveWindowGeometry(int x, int y, int width, int height, bool maximized);

signals:
    void darkModeChanged();
    void textScaleChanged();
    void themeColorsChanged();
    void viewModeChanged();
    void lastCalendarIdChanged();

private:
    void loadOmarchyTheme();
    void watchOmarchyTheme();

    bool m_darkMode = true;
    qreal m_textScale = 1.0;
    QString m_themeBackground;
    QString m_themeForeground;
    QString m_themeAccent;
    QString m_themeDanger;
    QStringList m_themePalette;
    QString m_viewMode;
    QString m_lastCalendarId;
    QFileSystemWatcher m_themeWatcher;
};
