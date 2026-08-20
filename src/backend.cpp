#include "backend.h"

#include <QColor>
#include <QDir>
#include <QFile>
#include <QRect>
#include <QSettings>
#include <QTextStream>

namespace {
const auto windowGeometrySetting = QStringLiteral("window/geometry");
const auto viewModeSetting = QStringLiteral("view/mode");
const auto lastCalendarSetting = QStringLiteral("event/lastCalendar");

QString omarchyThemeDirectory() {
    return QDir::homePath() + QStringLiteral("/.local/state/omarchy/current/theme");
}
}

Backend::Backend(QObject *parent) : QObject(parent) {
    const QSettings settings;
    m_viewMode = settings.value(viewModeSetting, QStringLiteral("month")).toString();
    m_lastCalendarId = settings.value(lastCalendarSetting).toString();

    loadOmarchyTheme();
    watchOmarchyTheme();

    // Theme switches replace the `current` symlink, so the watcher fires for
    // the directory rather than the file; re-arm it every time because a
    // replaced file drops out of the watch list.
    const auto onThemeChange = [this]() {
        loadOmarchyTheme();
        watchOmarchyTheme();
    };
    connect(&m_themeWatcher, &QFileSystemWatcher::fileChanged, this, onThemeChange);
    connect(&m_themeWatcher, &QFileSystemWatcher::directoryChanged, this, onThemeChange);
}

QHash<QString, QString> Backend::colorsFromFile(const QString &path) {
    QHash<QString, QString> colors;
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly | QIODevice::Text))
        return colors;

    QTextStream in(&file);
    while (!in.atEnd()) {
        const QString line = in.readLine().trimmed();
        if (line.isEmpty() || line.startsWith(QLatin1Char('#')))
            continue;

        const int equals = line.indexOf(QLatin1Char('='));
        if (equals < 0)
            continue;

        const QString key = line.left(equals).trimmed();
        QString value = line.mid(equals + 1).trimmed();
        if (value.size() >= 2
                && ((value.front() == QLatin1Char('"') && value.back() == QLatin1Char('"'))
                    || (value.front() == QLatin1Char('\'') && value.back() == QLatin1Char('\''))))
            value = value.mid(1, value.size() - 2);

        colors.insert(key, value);
    }
    return colors;
}

void Backend::loadOmarchyTheme() {
    m_themeBackground = m_darkMode ? QStringLiteral("#101010") : QStringLiteral("#ffffff");
    m_themeForeground = m_darkMode ? QStringLiteral("#eeeeee") : QStringLiteral("#222324");
    m_themeAccent = m_darkMode ? QStringLiteral("#5584aa") : QStringLiteral("#2077b2");
    m_themeDanger = QStringLiteral("#e05555");

    const QHash<QString, QString> colors =
        colorsFromFile(omarchyThemeDirectory() + QStringLiteral("/colors.toml"));

    const auto take = [&colors](const QString &key, QString &into) {
        const QString value = colors.value(key);
        if (!value.isEmpty())
            into = value;
    };
    take(QStringLiteral("background"), m_themeBackground);
    take(QStringLiteral("foreground"), m_themeForeground);
    take(QStringLiteral("accent"), m_themeAccent);
    take(QStringLiteral("red"), m_themeDanger);

    // Calendars without a stored color get one of these, so untinted EDS
    // sources still spread across the theme's own palette.
    m_themePalette.clear();
    const QStringList paletteKeys = {
        QStringLiteral("blue"), QStringLiteral("green"), QStringLiteral("orange"),
        QStringLiteral("magenta"), QStringLiteral("yellow"), QStringLiteral("cyan"),
        QStringLiteral("red"),
    };
    for (const QString &key : paletteKeys) {
        const QString value = colors.value(key);
        if (!value.isEmpty() && QColor(value).isValid())
            m_themePalette.append(value);
    }
    if (m_themePalette.isEmpty())
        m_themePalette.append(m_themeAccent);

    // The theme's own light/dark statement wins over the portal, matching how
    // the rest of omarchy treats a theme switch.
    const QString themeMode = colors.value(QStringLiteral("mode"));
    bool themeModeKnown = false;
    bool themeIsDark = m_darkMode;
    if (themeMode == QStringLiteral("dark")) {
        themeIsDark = true;
        themeModeKnown = true;
    } else if (themeMode == QStringLiteral("light")) {
        themeIsDark = false;
        themeModeKnown = true;
    } else {
        const QColor background(m_themeBackground);
        if (background.isValid()) {
            const double luminance = 0.299 * background.redF()
                + 0.587 * background.greenF() + 0.114 * background.blueF();
            themeIsDark = luminance < 0.5;
            themeModeKnown = true;
        }
    }
    if (themeModeKnown && themeIsDark != m_darkMode) {
        m_darkMode = themeIsDark;
        emit darkModeChanged();
    }

    emit themeColorsChanged();
}

void Backend::watchOmarchyTheme() {
    const QStringList watched = m_themeWatcher.files() + m_themeWatcher.directories();
    if (!watched.isEmpty())
        m_themeWatcher.removePaths(watched);

    const QString currentDir = QDir::homePath()
        + QStringLiteral("/.local/state/omarchy/current");
    const QString themeDir = currentDir + QStringLiteral("/theme");
    const QString colorsPath = themeDir + QStringLiteral("/colors.toml");

    if (QDir(currentDir).exists())
        m_themeWatcher.addPath(currentDir);
    if (QDir(themeDir).exists())
        m_themeWatcher.addPath(themeDir);
    if (QFile::exists(colorsPath))
        m_themeWatcher.addPath(colorsPath);
}

void Backend::setDarkMode(bool darkMode) {
    if (m_darkMode == darkMode)
        return;

    m_darkMode = darkMode;
    loadOmarchyTheme();
    emit darkModeChanged();
}

void Backend::setTextScale(qreal textScale) {
    if (qFuzzyCompare(m_textScale, textScale))
        return;

    m_textScale = textScale;
    emit textScaleChanged();
}

void Backend::setViewMode(const QString &viewMode) {
    if (m_viewMode == viewMode)
        return;

    m_viewMode = viewMode;
    QSettings settings;
    settings.setValue(viewModeSetting, m_viewMode);
    emit viewModeChanged();
}

void Backend::setLastCalendarId(const QString &calendarId) {
    if (m_lastCalendarId == calendarId)
        return;

    m_lastCalendarId = calendarId;
    QSettings settings;
    settings.setValue(lastCalendarSetting, m_lastCalendarId);
    emit lastCalendarIdChanged();
}

QVariantMap Backend::windowGeometry() const {
    QSettings settings;
    const QRect geometry = settings.value(windowGeometrySetting).toRect();

    QVariantMap map;
    // Positions can legitimately be negative on monitors left of or above the
    // primary, so validity travels separately instead of being encoded as -1.
    map.insert(QStringLiteral("valid"), geometry.isValid());
    map.insert(QStringLiteral("x"), geometry.x());
    map.insert(QStringLiteral("y"), geometry.y());
    map.insert(QStringLiteral("width"), geometry.width());
    map.insert(QStringLiteral("height"), geometry.height());
    map.insert(QStringLiteral("maximized"),
               settings.value(QStringLiteral("window/maximized"), false).toBool());
    return map;
}

void Backend::saveWindowGeometry(int x, int y, int width, int height, bool maximized) {
    QSettings settings;
    settings.setValue(windowGeometrySetting, QRect(x, y, width, height));
    settings.setValue(QStringLiteral("window/maximized"), maximized);
}
