#include "systemtheme.h"

#include <QDBusConnection>
#include <QDBusMessage>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>
#include <QDBusVariant>
#include <QGuiApplication>
#include <QStyleHints>
#include <QVariant>

namespace {
QVariant unwrapVariant(QVariant value) {
    while (value.canConvert<QDBusVariant>())
        value = value.value<QDBusVariant>().variant();
    return value;
}

bool colorSchemeIsDark(const QVariant &value, bool *known) {
    bool ok = false;
    const uint scheme = unwrapVariant(value).toUInt(&ok);
    if (!ok)
        return false;

    if (scheme == 1) {
        *known = true;
        return true;
    }
    if (scheme == 2) {
        *known = true;
        return false;
    }

    return false;
}

// GNOME's text-scaling-factor is the desktop-wide "apparent text size" knob;
// omarchy drives it from `omarchy display text size`, anchored so the default
// 12px maps to 1.0. Ignore nonsense values and cap the range GNOME allows.
qreal sanitizedTextScale(const QVariant &value, bool *known) {
    bool ok = false;
    const qreal scale = unwrapVariant(value).toDouble(&ok);
    if (!ok || scale <= 0)
        return 1.0;

    *known = true;
    return qBound(0.5, scale, 3.0);
}

bool gsettingsSchemeIsDark(const QVariant &value, bool *known) {
    const QString scheme = unwrapVariant(value).toString();
    if (scheme.contains(QStringLiteral("prefer-dark"))) {
        *known = true;
        return true;
    }
    if (scheme.contains(QStringLiteral("prefer-light"))) {
        *known = true;
        return false;
    }

    return false;
}
}

SystemTheme::SystemTheme(QObject *parent) : QObject(parent) {
    // The defaults must stand before first paint; the portal's answers
    // refine them whenever they arrive, through the change notifications.
    m_darkMode = fallbackDarkMode();

    if (QGuiApplication::styleHints()) {
        connect(QGuiApplication::styleHints(), &QStyleHints::colorSchemeChanged,
                this, &SystemTheme::refresh);
    }

    QDBusConnection::sessionBus().connect(
        QString(),
        QStringLiteral("/org/freedesktop/portal/desktop"),
        QStringLiteral("org.freedesktop.portal.Settings"),
        QStringLiteral("SettingChanged"),
        this,
        SLOT(handlePortalSettingChanged(QString,QString,QDBusVariant)));

    refresh();
}

void SystemTheme::refresh() {
    requestPortalSetting(QStringLiteral("org.freedesktop.appearance"),
                         QStringLiteral("color-scheme"));
    requestPortalSetting(QStringLiteral("org.gnome.desktop.interface"),
                         QStringLiteral("text-scaling-factor"));
}

// Ask the desktop portal for a single setting without ever blocking the GUI
// thread: a missing or stalled portal must not hold up first paint. The
// current value stands until the answer (or failure) reaches
// applyPortalSetting.
void SystemTheme::requestPortalSetting(const QString &nameSpace, const QString &key) {
    const QDBusConnection bus = QDBusConnection::sessionBus();
    if (!bus.isConnected()) {
        applyPortalSetting(key, QVariant());
        return;
    }

    QDBusMessage request = QDBusMessage::createMethodCall(
        QStringLiteral("org.freedesktop.portal.Desktop"),
        QStringLiteral("/org/freedesktop/portal/desktop"),
        QStringLiteral("org.freedesktop.portal.Settings"),
        QStringLiteral("Read"));
    request << nameSpace << key;

    auto *watcher = new QDBusPendingCallWatcher(bus.asyncCall(request), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this,
            [this, key](QDBusPendingCallWatcher *watcher) {
        const QDBusPendingReply<QDBusVariant> reply = *watcher;
        applyPortalSetting(key, reply.isValid() ? reply.value().variant() : QVariant());
        watcher->deleteLater();
    });
}

void SystemTheme::applyPortalSetting(const QString &key, const QVariant &value) {
    if (key == QStringLiteral("text-scaling-factor")) {
        bool known = false;
        setTextScale(sanitizedTextScale(value, &known));
        return;
    }

    // color-scheme: an unknown or missing answer falls back to Qt's scheme.
    bool known = false;
    const bool dark = colorSchemeIsDark(value, &known);
    setDarkMode(known ? dark : fallbackDarkMode());
}

void SystemTheme::handlePortalSettingChanged(const QString &nameSpace, const QString &key,
                                             const QDBusVariant &value) {
    if (key == QStringLiteral("text-scaling-factor")) {
        if (nameSpace != QStringLiteral("org.gnome.desktop.interface"))
            return;

        bool known = false;
        const qreal scale = sanitizedTextScale(value.variant(), &known);
        if (known)
            setTextScale(scale);
        return;
    }

    if (key != QStringLiteral("color-scheme"))
        return;

    bool known = false;
    bool dark = false;
    if (nameSpace == QStringLiteral("org.freedesktop.appearance"))
        dark = colorSchemeIsDark(value.variant(), &known);
    else if (nameSpace == QStringLiteral("org.gnome.desktop.interface"))
        dark = gsettingsSchemeIsDark(value.variant(), &known);
    else
        return;

    if (known)
        setDarkMode(dark);
    else
        refresh();
}

// The portal-less answer: Qt's own scheme when it knows one, dark otherwise.
bool SystemTheme::fallbackDarkMode() const {
    bool known = false;
    const bool dark = qtDarkMode(&known);
    return known ? dark : true;
}

bool SystemTheme::qtDarkMode(bool *known) const {
    *known = false;

    if (!QGuiApplication::styleHints())
        return false;

    const Qt::ColorScheme scheme = QGuiApplication::styleHints()->colorScheme();
    if (scheme == Qt::ColorScheme::Dark) {
        *known = true;
        return true;
    }
    if (scheme == Qt::ColorScheme::Light) {
        *known = true;
        return false;
    }

    return false;
}

void SystemTheme::setDarkMode(bool darkMode) {
    if (m_darkMode == darkMode)
        return;

    m_darkMode = darkMode;
    emit darkModeChanged(m_darkMode);
}

void SystemTheme::setTextScale(qreal textScale) {
    if (qFuzzyCompare(m_textScale, textScale))
        return;

    m_textScale = textScale;
    emit textScaleChanged(m_textScale);
}
